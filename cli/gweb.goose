// gweb: the gweb command line.
//
//   gweb [-C dir] new <dir>
//   gweb [-C dir] gen [--no-minify]
//   gweb [-C dir] build [--debug] [--no-minify] | routes
//   gweb [-C dir] start [--no-minify] [server flags...]
//   gweb [-C dir] dev [server flags...]
//   gweb [-C dir] test | check | lsp
//   gweb version
//
// gen, build, start and test also take --strict (any warning fails the run) and
// --diagnostics json (stderr as JSON Lines: severity, file, line, code, message[, detail]).

import std;
import os;
import component;
import i18n;
import tscan;
import html;
import pins;

// ---------------------------------------------------------------- C helpers (proc.c)

extern fn c_run(cmd: const u8[:], out: u8[>..]&) -> i32 = "gweb_run";
extern fn c_spawn(cmd: const u8[:]) -> i64 = "gweb_spawn";
extern fn c_exec(cmd: const u8[:]) -> i32 = "gweb_exec";
extern fn c_kill(pid: i64, sig: i32) -> i32 = "gweb_kill";
extern fn c_wait(pid: i64, blocking: i32) -> i32 = "gweb_wait";
extern fn c_symlink(target: const u8[:], path: const u8[:]) -> i32 = "gweb_symlink";
extern fn c_chdir(path: const u8[:]) -> i32 = "gweb_chdir";
extern fn c_cwd(out: u8[>..]&) -> i32 = "gweb_cwd";
extern fn c_remove_tree(path: const u8[:]) -> i32 = "gweb_remove_tree";
extern fn c_tree_stamp(path: const u8[:], count: i64&) -> i64 = "gweb_tree_stamp";

// gzip.c: appends the gzip of data to out; 0 when it failed.
extern fn c_gzip(data: const u8[:], out: u8[>..]&) -> i32 = "gweb_gzip";

// ---------------------------------------------------------------- model

struct Dir {
    rel: u8[..512],
    root: u8[..512],       // the folder holding this directory's files: app/users, or PKGDIR/app/users for a mounted package
    route: bool, page_html: bool, page_goose: bool, layout: bool, middleware: bool,
    methods: i64,          // bit i set: METHODS[i] is defined in route.goose
    has_load: bool, has_before: bool, has_after: bool,
    has_post: bool,
    has_post_res: bool = false, has_load_res: bool = false,   // fn POST( / fn load( take a third parameter, res: http::Response&
    frags: u8[..600],      // the page's fragment names, space-separated
    route_ns: u8[..200], page_ns: u8[..200], layout_ns: u8[..32], mw_ns: u8[..32],
    page_csrf: bool = false, layout_csrf: bool = false, csrf_const: bool = false,   // csrf_const: route.goose declares const CSRF
    max_upload: bool = false,     // page.goose or route.goose declares const MAX_UPLOAD
    error_html: bool = false, error_ns: u8[..32] = "", error_csrf: bool = false,   // error.html in this folder (DESIGN-ADDENDUM-14, D10)
    loading: bool = false, loading_ns: u8[..32] = "",   // loading.html in this folder (DESIGN-ADDENDUM-14, section 4)
    in_sitemap: bool = true,                                                         // false: page.goose has const SITEMAP = false;
    revalidate: i64 = 0,                                                             // seconds from const REVALIDATE = N;, 0 = not cached
    static_paths: bool = false                                                       // page.goose defines fn static_paths(
}

// A gweb package (DESIGN-ADDENDUM-18, D6). mount is the URL prefix without its leading slash, "" when the package has no `at`.
struct Pkg { name: u8[..64], dir: u8[..512], mount: u8[..512], git: bool, line: i64 }

// hashed is url with the first 8 hex digits of etag before the last extension; both URLs serve the same bytes.
// embed is the file the binary embeds when that is not file (minified CSS); min says file must be minified to get the served bytes.
// gz is the static_bytes index of the gzip variant, or -1.
struct Static { url: u8[..512], file: u8[..512], ctype: u8[..64], etag: u8[..24], hashed: u8[..520], embed: u8[..512], min: bool, gz: i64 }

// own is the page's dir index, or -1 in a layout, not-found.html or a component.
struct Target { path: u8[..512], line: i64, url: u8[..512], name: u8[..64], post: bool, own: i64 }

// ns is the test file's namespace, name the function.
struct TestFn { ns: u8[..80], name: u8[..64] }

let K_PAGE = 0;
let K_LAYOUT = 1;
let K_NOT_FOUND = 2;
let K_ERROR = 3;
let K_LOADING = 4;

let METHODS =["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"];
let VARIANTS = ["Get", "Head", "Post", "Put", "Patch", "Delete", "Options"];

var dirs: Dir[>..<];
var statics: Static[>..<];
var pkgs: Pkg[>..<];
var errors = 0;
var has_state = false;
var has_state_init = false;
var has_config = false;
var has_sitemap = false;               // app/sitemap.goose exists
var has_entries = false;               // and defines fn entries(
var has_robots = false;                // and defines fn robots(
var has_socket = false;                // app/socket.goose exists
var socket_open = false;               // and defines these handlers
var socket_message = false;
var socket_close = false;
var uses_hub = false;                  // socket.goose, or a file under app/ or lib/ calls gweb::subscribe( or gweb::websocket(
var has_state_shutdown = false;
var has_jobs = false;
var has_jobs_schedule = false;
var has_not_found = false;
var not_found_csrf = false;
var uses_sqlite = false;
var uses_keys = false;   // code or templates call gweb::login, gweb::session or the signed cookie functions
var map_text: u8[>..];
var srcmap_text: u8[>..];
var gen_root: u8[>..];
var minify = false;                    // gweb build, start and gen turn it on; dev and test leave it off
// gweb test must never touch BUILD_DIR: a built server or a running gweb dev depends on it.
let TEST_DIR = ".gooseweb.test";
let BUILD_DIR = ".gooseweb";
let LSP_DIR = ".gooseweb.lsp";
let CHECK_DIR = ".gooseweb.check";
var overlay_src: u8[>..];              // lsp-gen --overlay: this source is read from overlay_tmp instead
var overlay_tmp: u8[>..];
var start_cwd: u8[>..];                // the folder gweb started in, before any -C
var component_names: u8[..64][>..<];
var component_paths: u8[..512][>..<];   // component_paths[i] is the source file of component_names[i]
var store_names: u8[..64][>..<];       // stores/Name.gshtml (Addendum 12 section 7.7)
var component_lines: i64[>..<];
var component_reactive: i64[>..<];     // 1 for a component with @ declarations (parallel to component_names)
var component_props: u8[>..];          // `Name\tprop\tdefault source\n` for each @prop of each reactive component
var component_errors = 0;              // translator errors of this gen; the build still runs goose
var uses_fragments = false;
var has_locales = false;              // locales/ exists: .gooseweb/t.goose is generated
var locale_notes: u8[>..];             // the 'lacks' lines, printed after a successful build
var locale_count = 0;
var uses_boost = false;               // a layout or page has <body gw-boost> (serves gwn.js)
var uses_trans = false;               // markup uses gw-enter or gw-leave (serves gwt.js)
var uses_sse = false;                 // markup uses gw-sse (serves gwe.js, and gws.js which it imports)
var uses_mods = false;                // a component imports gwm.js (on: modifiers)
var uses_life = false;                // a component calls life() (imports gwl.js)
var uses_children = false;            // a component calls a child component (imports gwc.js)
var uses_stores = false;              // the site has a store (stores/*.gshtml, serves gws.js)
var uses_http = false;                 // a component imports gwh.js (http::get or http::post)
var http_calls: Target[>..<];          // each string-literal url of an http call (post: POST, name: get or post)
var targets: Target[>..<];
var tpl_script = false;
var tpl_boost = false;
var tpl_trans = false;
var tpl_sse = false;
var last_errors: u8[>..];
var test_files: u8[..80][>..<];        // t_<name>, one per tests/<name>.goose
var test_fns: TestFn[>..<];
var warnings = 0;
var last_warnings: u8[>..];
var strict = false;                    // --strict: warnings fail the run
var json_diag = false;                 // --diagnostics json
var debug_flag = false;                // build --debug

fn note_errors(text: const u8[:]) {
    let room = 16384 - last_errors.len;
    if room > 0 { last_errors.append(text[..min(text.len, room)]); }
}

fn note_warnings(text: const u8[:]) {
    let room = 16384 - last_warnings.len;
    if room > 0 { last_warnings.append(text[..min(text.len, room)]); }
}

// ---------------------------------------------------------------- small helpers

// One diagnostic: sev is "error" or "warning". Text mode prints path:line: sev: msg; json mode
// one JSON object. dev reads the text form from last_errors and last_warnings.
fn diag(sev: const u8[:], path: const u8[:], line: i64, code: const u8[:], msg: const u8[:]) {
    var s: u8[>..] = [];
    if line > 0 { format(s, path, ":", line, ": ", sev, ": ", msg, "\n"); } else { format(s, path, ": ", sev, ": ", msg, "\n"); }
    if json_diag {
        var j: u8[>..] = [];
        json_head(j, sev, path, line, code, msg);
        j.append("}\n");
        write_stderr(j);
    } else {
        write_stderr(s);
    }
    if sev == "error" { note_errors(s); errors += 1; } else { note_warnings(s); warnings += 1; }
}

fn err(path: const u8[:], line: i64, msg: const u8[:]) { diag("error", path, line, "", msg); }

fn warn(path: const u8[:], line: i64, code: const u8[:], msg: const u8[:]) { diag("warning", path, line, code, msg); }

// A gweb line that is not about a file: text as is, a JSON object with an empty file in json mode. Not counted.
fn say_error(msg: const u8[:]) {
    if !json_diag { write_stderr(msg); write_stderr("\n"); return; }
    var j: u8[>..] = [];
    json_head(j, "error", "", 0, "", msg);
    j.append("}\n");
    write_stderr(j);
}

fn json_str(out: u8[>..]&, s: const u8[:]) {
    let hex = "0123456789abcdef";
    out.push('"');
    for c in s {
        if c == '"' { out.append("\\\""); }
        else if c == '\\' { out.append("\\\\"); }
        else if c == '\n' { out.append("\\n"); }
        else if c == '\t' { out.append("\\t"); }
        else if c == '\r' { out.append("\\r"); }
        else if c < 32 { out.append("\\u00"); out.push(hex[c >> 4]); out.push(hex[c & 15]); }
        else { out.push(c); }
    }
    out.push('"');
}

// The object up to and including "message"; the caller adds "detail" and the closing brace.
fn json_head(out: u8[>..]&, sev: const u8[:], path: const u8[:], line: i64, code: const u8[:], msg: const u8[:]) {
    format(out, "{\"severity\":\"", sev, "\",\"file\":");
    json_str(out, path);
    format(out, ",\"line\":", line, ",\"code\":");
    json_str(out, code);
    out.append(",\"message\":");
    json_str(out, msg);
}

fn last_colon(s: const u8[:]) -> i64 {
    var i = s.len;
    while i > 0 { i -= 1; if s[i] == ':' { return i; } }
    return -1;
}

// Splits `path:line[:col]: (error|warning): message`; false when line is not of that shape.
fn split_diag(line: const u8[:], path: u8[>..]&, ln: i64&, is_err: bool&, msg: u8[>..]&) -> bool {
    let ke = find(line, ": error: ");
    let kw = find(line, ": warning: ");
    var k = ke;
    var klen = 9;
    var e = true;
    if kw >= 0 && (ke < 0 || kw < ke) { k = kw; klen = 11; e = false; }
    if k < 0 { return false; }
    let head = line[..k];
    var lnum = 0;
    var hp = head;
    let a = last_colon(head);
    if a >= 0 {
        let n1, ok1 = parse_int(head[a + 1..]);
        if ok1 {
            lnum = n1;
            hp = head[..a];
            let b = last_colon(hp);
            if b >= 0 {
                let n2, ok2 = parse_int(hp[b + 1..]);
                if ok2 { lnum = n2; hp = hp[..b]; }
            }
        }
    }
    path.append(hp);
    ln = lnum;
    is_err = e;
    msg.append(line[k + klen..]);
    return true;
}

fn flush_diag(out: u8[>..]&, head: u8[>..]&, detail: u8[>..]&) {
    if head.len == 0 { return; }
    out.append(head);
    if detail.len > 0 { out.append(",\"detail\":"); json_str(out, detail); }
    out.append("}\n");
    head.clear();
    detail.clear();
}

// Compiler output (Goose's or the component translator's) to stderr: as is, or as JSON Lines in
// json mode, where a line that is not a diagnostic goes into the previous object's "detail".
fn print_compiler(text: const u8[:]) {
    if !json_diag { write_stderr(text); return; }
    var out: u8[>..] = [];
    var head: u8[>..] = [];
    var detail: u8[>..] = [];
    for line in split(text, '\n') {
        if line.len == 0 { continue; }
        var path: u8[>..] = [];
        var msg: u8[>..] = [];
        var ln = 0;
        var is_err = true;
        if split_diag(line, path, ln, is_err, msg) {
            flush_diag(out, head, detail);
            json_head(head, if is_err { "error" } else { "warning" }, path, ln, "", msg);
        } else if head.len == 0 {
            json_head(head, "error", "", 0, "", line);
        } else {
            if detail.len > 0 { detail.push('\n'); }
            detail.append(line);
        }
    }
    flush_diag(out, head, detail);
    write_stderr(out);
}

// Component warnings: `code\tpath:LINE: warning: MSG` lines.
fn emit_component_warnings(w: const u8[:]) {
    for line in split(w, '\n') {
        let code, rest, ok = split_once(line, '\t');
        if !ok { continue; }
        var path: u8[>..] = [];
        var msg: u8[>..] = [];
        var ln = 0;
        var is_err = false;
        if split_diag(rest, path, ln, is_err, msg) { warn(path, ln, code, msg); }
    }
}

// Takes gweb's own flags out of rest; the rest of rest is not looked at.
fn parse_flags(rest: u8[:][:], allow_debug: bool) {
    var i = 0;
    while i < rest.len {
        if rest[i] == "--strict" { strict = true; }
        else if rest[i] == "--debug" && allow_debug { debug_flag = true; }
        else if rest[i] == "--diagnostics" {
            if i + 1 >= rest.len || rest[i + 1] != "json" { say_error("gweb: --diagnostics takes json"); exit(2); }
            json_diag = true;
            i += 1;
        }
        i += 1;
    }
}

// After everything is printed: under --strict, warnings fail the run.
fn strict_ok() -> bool {
    if !strict || warnings == 0 { return true; }
    var m: u8[>..] = [];
    format(m, "gweb: --strict: ", warnings, " warnings stop the build");
    say_error(m);
    return false;
}

fn is_ident(s: const u8[:]) -> bool {
    if s.len == 0 { return false; }
    for c, i in s {
        let alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
        let digit = c >= '0' && c <= '9';
        if !alpha && !(digit && i > 0) { return false; }
    }
    return true;
}

fn slug(out: u8[>..]&, rel: const u8[:]) {
    for c in rel {
        let ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
        if ok { out.push(c); } else if c != '[' && c != ']' { out.push('_'); }
    }
}

fn shq(out: u8[>..]&, s: const u8[:]) {
    out.push('\'');
    for c in s { if c == '\'' { out.append("'\\''"); } else { out.push(c); } }
    out.push('\'');
}

fn lit(out: u8[>..]&, s: const u8[:]) {
    let hex = "0123456789abcdef";
    for c in s {
        if c == '"' { out.append("\\\""); }
        else if c == '\\' { out.append("\\\\"); }
        else if c == '\n' { out.append("\\n"); }
        else if c == '\t' { out.append("\\t"); }
        else if c == '\r' { out.append("\\r"); }
        else if c < 32 || c == 127 { out.append("\\x"); out.push(hex[c >> 4]); out.push(hex[c & 15]); }
        else { out.push(c); }
    }
}

fn defines(src: const u8[:], name: const u8[:]) -> bool {
    var pat: u8[>..] = [];
    format(pat, "fn ", name, "(");
    for line in split(src, '\n') { if starts_with(trim_start(line), pat) { return true; } }
    return false;
}

// True when the line that starts `fn name(` mentions http::Response: the handler takes res (D14).
fn takes_res(src: const u8[:], name: const u8[:]) -> bool {
    var pat: u8[>..] = [];
    format(pat, "fn ", name, "(");
    for line in split(src, '\n') {
        if starts_with(trim_start(line), pat) { return find(line, "http::Response") >= 0; }
    }
    return false;
}

// True when a line starts with enum NAME or struct NAME followed by a space or {.
fn declares_type(src: const u8[:], name: const u8[:]) -> bool {
    for line in split(src, '\n') {
        let l = trim_start(line);
        for kw in ["enum ", "struct "] {
            if !starts_with(l, kw) { continue; }
            let rest = l[kw.len..];
            if starts_with(rest, name) && (rest.len == name.len || rest[name.len] == ' ' || rest[name.len] == '{') { return true; }
        }
    }
    return false;
}

fn mentions_csrf(src: const u8[:]) -> bool { find(src, "gweb::csrf_") >= 0 }

fn mentions_keys(src: const u8[:]) -> bool {
    for w in ["gweb::login", "gweb::session", "gweb::signed_cookie", "gweb::set_signed_cookie"] { if find(src, w) >= 0 { return true; } }
    return false;
}

// True when code declares const CSRF in route.goose; reports a malformed declaration, or any in a page.goose.
fn csrf_const(path: const u8[:], code: const u8[:], route: bool) -> bool {
    var found = false;
    for line, i in split(code, '\n') {
        let t = trim_start(line);
        if !starts_with(t, "const CSRF") { continue; }
        if t.len > 10 && (is_ident(t[10..11]) || (t[10] >= '0' && t[10] <= '9')) { continue; }
        if !route { err(path, i + 1, "const CSRF belongs in route.goose; a page's POST always checks the token"); return false; }
        if starts_with(t, "const CSRF = false;") || starts_with(t, "const CSRF = true;") { found = true; }
        else { err(path, i + 1, "write const CSRF = false; to turn off this route's CSRF check (or const CSRF = true;)"); }
    }
    return found;
}

// False when code has const SITEMAP = false; a malformed declaration is reported and leaves the page listed.
fn sitemap_listed(path: const u8[:], code: const u8[:]) -> bool {
    var listed = true;
    for line, i in split(code, '\n') {
        let t = trim_start(line);
        if !starts_with(t, "const SITEMAP") { continue; }
        if t.len > 13 && (is_ident(t[13..14]) || (t[13] >= '0' && t[13] <= '9')) { continue; }
        if starts_with(t, "const SITEMAP = false;") { listed = false; }
        else if !starts_with(t, "const SITEMAP = true;") { err(path, i + 1, "write const SITEMAP = false; to leave this page out of /sitemap.xml (or const SITEMAP = true;)"); }
    }
    return listed;
}

// N of const REVALIDATE = N; or 0 when absent; a declaration that is not a whole number above 0 is reported and counts as absent.
fn revalidate_const(path: const u8[:], code: const u8[:]) -> i64 {
    var secs = 0;
    for line, i in split(code, '\n') {
        let t = trim_start(line);
        if !starts_with(t, "const REVALIDATE") { continue; }
        if t.len > 16 && (is_ident(t[16..17]) || (t[16] >= '0' && t[16] <= '9')) { continue; }
        var n = -1;
        let r = trim(t[16..]);
        if r.len > 2 && r[0] == '=' && r[r.len - 1] == ';' {
            let digits = trim(r[1..r.len - 1]);
            if digits.len > 0 && digits.len <= 9 {
                n = 0;
                for c in digits {
                    if c < '0' || c > '9' { n = -1; break; }
                    n = n * 10 + (c - '0');
                }
            }
        }
        if n > 0 { secs = n; }
        else { err(path, i + 1, "write const REVALIDATE = N; with N the seconds to cache this page, a whole number above 0"); }
    }
    return secs;
}

fn has_static(url: const u8[:]) -> bool {
    for s in statics { if s.url == url { return true; } }
    return false;
}

fn read_src(path: const u8[:], out: u8[>..]&) -> bool {
    if overlay_src.len > 0 && path == overlay_src { return read_file(overlay_tmp, out); }
    return read_file(path, out);
}

fn read(path: const u8[:], out: u8[>..]&) -> bool {
    if !read_src(path, out) { err(path, 0, "cannot read"); return false; }
    return true;
}

fn write(path: const u8[:], data: const u8[:]) {
    if !write_file(path, data) { err(path, 0, "cannot write"); }
}

fn is_ancestor(a: const u8[:], b: const u8[:]) -> bool {
    if a.len == 0 || a == b { return true; }
    return b.len > a.len && starts_with(b, a) && b[a.len] == '/';
}

fn app_path(out: u8[>..]&, d: const Dir&, file: const u8[:]) {
    out.append(d.root);
    out.push('/');
    out.append(file);
}

fn url_of(out: u8[>..]&, rel: const u8[:]) { out.push('/'); out.append(rel); }

// ---------------------------------------------------------------- packages

// A gweb package is listed in gweb.packages, one `SOURCE [at /prefix]` per line (DESIGN-ADDENDUM-18, D6).
let PKG_LIST = "gweb.packages";
let PKG_RESERVED = ["lib", "std", "os", "gweb", "web", "net", "sqlite", "main", "state"];

// owner/repo@tag: one '/', an '@' after it, and not a path.
fn is_git_source(src: const u8[:]) -> bool {
    if src.len == 0 || src[0] == '.' || src[0] == '/' || find(src, "@") < 0 { return false; }
    var slashes = 0;
    for c in src { if c == '/' { slashes += 1; } }
    return slashes == 1;
}

fn git_part_ok(s: const u8[:], plus: bool) -> bool {
    if s.len == 0 || s[0] == '.' || s[0] == '-' { return false; }
    for c in s {
        let ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-' || (plus && c == '+');
        if !ok { return false; }
    }
    return true;
}

// The mount without its leading slash: literal folder names only, as a route is.
fn mount_ok(prefix: const u8[:]) -> bool {
    if prefix.len == 0 || prefix.len > 200 { return false; }
    for seg in split(prefix, '/') {
        if seg.len == 0 || seg_kind(seg) != 0 || seg[0] == '_' || seg[0] == '.' { return false; }
        for c in seg {
            let ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-' || c == '~';
            if !ok { return false; }
        }
    }
    return true;
}

// Clones owner/repo@tag into the cache when it is not there; never updates a cached tag. dir gets the folder.
fn fetch_git(line: i64, src: const u8[:], dir: u8[>..]&) -> bool {
    let slash = find(src, "/");
    let at = find(src, "@");
    var m: u8[>..] = [];
    if at < slash { format(m, src, ": a git source is owner/repo@tag"); err(PKG_LIST, line, m); return false; }
    let owner = src[..slash];
    let repo = src[slash + 1..at];
    let tag = src[at + 1..];
    if !git_part_ok(owner, false) || !git_part_ok(repo, false) || !git_part_ok(tag, true) {
        format(m, src, ": a git source is owner/repo@tag, with letters, digits, . _ - in each part");
        err(PKG_LIST, line, m);
        return false;
    }
    var cache: u8[>..] = [];
    var v: u8[>..] = [];
    var home: u8[>..] = [];
    if env("GWEB_PKG_CACHE", v) && v.len > 0 { cache.append(v); }
    else if env("HOME", home) && home.len > 0 { format(cache, home, "/.cache/gweb/pkgs"); }
    else { err(PKG_LIST, line, "set HOME or GWEB_PKG_CACHE to fetch git packages"); return false; }
    while cache.len > 1 && cache[cache.len - 1] == '/' { cache.pop(); }
    format(dir, cache, "/", src);
    if is_dir(dir) { return true; }
    var parent: u8[>..] = [];
    format(parent, cache, "/", owner);
    var cmd: u8[>..] = [];
    var out: u8[>..] = [];
    cmd.append("mkdir -p ");
    shq(cmd, parent);
    c_run(cmd, out);
    cmd.clear();
    out.clear();
    var url: u8[>..] = [];
    format(url, "https://github.com/", owner, "/", repo);
    cmd.append("git clone --depth 1 --branch ");
    shq(cmd, tag);
    cmd.push(' ');
    shq(cmd, url);
    cmd.push(' ');
    shq(cmd, dir);
    if c_run(cmd, out) != 0 {
        format(m, src, ": git clone failed: ", trim(out));
        err(PKG_LIST, line, m);
        return false;
    }
    return true;
}

// Reads PKG/gweb.package: `name IDENT` and `gweb MAJOR.MINOR`, # comments. Returns the name, or false after reporting.
fn read_manifest(path: const u8[:], text: const u8[:], name: u8[..64]&) -> bool {
    var have_name = false;
    var have_ver = false;
    var ver_line = 0;
    var want_major: i64 = 0;
    var want_minor: i64 = 0;
    var want_text: u8[>..] = [];
    var good = true;
    for raw, i in split(text, '\n') {
        let t = trim(raw);
        if t.len == 0 || t[0] == '#' { continue; }
        let sp = find(t, " ");
        let key = t[..(if sp >= 0 { sp } else { t.len })];
        let val = trim(t[(if sp >= 0 { sp + 1 } else { t.len })..]);
        if key == "name" {
            if !is_ident(val) || val.len > 64 { err(path, i + 1, "name needs a Goose identifier, as in name admin"); good = false; }
            else { name.clear(); name.append(val); have_name = true; }
        } else if key == "gweb" {
            let parts = split(val, '.');
            var ok = parts.len == 2;
            var major: i64 = 0;
            var minor: i64 = 0;
            if ok {
                let a, aok = parse_int(parts[0]);
                let b, bok = parse_int(parts[1]);
                ok = aok && bok && a >= 0 && b >= 0;
                major = a;
                minor = b;
            }
            if !ok { err(path, i + 1, "gweb needs MAJOR.MINOR, as in gweb 0.3"); good = false; }
            else { have_ver = true; ver_line = i + 1; want_major = major; want_minor = minor; want_text.clear(); want_text.append(val); }
        } else {
            err(path, i + 1, "a line is `name IDENT` or `gweb MAJOR.MINOR`");
            good = false;
        }
    }
    if !have_name && good { err(path, 0, "needs a name line, as in name admin"); good = false; }
    if !have_ver && good { err(path, 0, "needs a gweb line, as in gweb 0.3"); good = false; }
    if !good { return false; }
    let cur = split(trim(EMBEDDED_VERSION), '.');
    if cur.len < 2 { return true; }
    let cmaj, ok1 = parse_int(cur[0]);
    let cmin, ok2 = parse_int(cur[1]);
    if !ok1 || !ok2 { return true; }
    if want_major > cmaj || (want_major == cmaj && want_minor > cmin) {
        var m: u8[>..] = [];
        format(m, name, ": needs gweb ", want_text, " or newer (this is ", trim(EMBEDDED_VERSION), ")");
        err(path, ver_line, m);
        return false;
    }
    return true;
}

// Resolves . and .. segments of an absolute path, so folders compare by name.
fn clean_path(p: const u8[:], out: u8[>..]&) {
    var segs: u8[..256][>..] = [];
    for seg in split(p, '/') {
        if seg.len == 0 || seg == "." { continue; }
        if seg == ".." { if segs.len > 0 { segs.pop(); } continue; }
        segs.push(seg);
    }
    for seg in segs { out.push('/'); out.append(seg); }
    if out.len == 0 { out.push('/'); }
}

fn load_packages() {
    pkgs.clear();
    if !file_exists(PKG_LIST) { return; }
    var text: u8[>..] = [];
    if !read(PKG_LIST, text) { return; }
    var cwd: u8[>..] = [];
    c_cwd(cwd);
    for raw, i in split(text, '\n') {
        let ln = i + 1;
        let t = trim(raw);
        if t.len == 0 || t[0] == '#' { continue; }
        var source: u8[>..] = [];
        var prefix: u8[>..] = [];
        let at = find(t, " at ");
        if at >= 0 || ends_with(t, " at") {
            var mnt: u8[>..] = [];
            if at >= 0 { source.append(trim(t[..at])); mnt.append(trim(t[at + 4..])); }
            else { source.append(trim(t[..t.len - 3])); }
            if mnt.len > 0 { prefix.append(mnt[1..]); }
            while prefix.len > 0 && prefix[prefix.len - 1] == '/' { prefix.pop(); }
            if mnt.len == 0 || mnt[0] != '/' || !mount_ok(prefix) {
                err(PKG_LIST, ln, "at needs a mount like /admin: literal folder names, no [id], no catch-all, not /");
                continue;
            }
        } else { source.append(t); }
        if source.len == 0 || find(source, " ") >= 0 || find(source, "\t") >= 0 { err(PKG_LIST, ln, "a line is SOURCE or SOURCE at /prefix"); continue; }
        var dir: u8[>..] = [];
        if is_git_source(source) { if !fetch_git(ln, source, dir) { continue; } }
        else if source[0] == '/' { dir.append(source); }
        else { format(dir, cwd, "/", source); }
        while dir.len > 1 && dir[dir.len - 1] == '/' { dir.pop(); }
        if dir.len >= 400 || !is_dir(dir) {
            var m: u8[>..] = [];
            format(m, source, ": not a folder (or the path is too long)");
            err(PKG_LIST, ln, m);
            continue;
        }
        var manifest: u8[>..] = [];
        format(manifest, dir, "/gweb.package");
        var mtext: u8[>..] = [];
        if !read_file(manifest, mtext) {
            var m: u8[>..] = [];
            format(m, source, ": no gweb.package in this folder");
            err(PKG_LIST, ln, m);
            continue;
        }
        var pk = Pkg { name: "", dir: "", mount: "", git: is_git_source(source), line: ln };
        if !read_manifest(manifest, mtext, pk.name) { continue; }
        pk.dir.append(dir);
        pk.mount.append(prefix);
        var m: u8[>..] = [];
        for r in PKG_RESERVED { if pk.name == r { format(m, pk.name, ": this package name is taken by a module; rename it"); } }
        for o in pkgs {
            if o.name == pk.name { format(m, pk.name, ": a second package with this name (", o.dir, ")"); }
            if prefix.len > 0 && o.mount.len > 0 && o.mount == prefix {
                format(m, pk.name, ": its mount /", prefix, " is also the mount of package ", o.name);
            }
        }
        if m.len > 0 { err(manifest, 0, m); continue; }
        var sub: u8[>..] = [];
        format(sub, dir, "/app");
        let has_app = is_dir(sub);
        sub.clear();
        format(sub, dir, "/public");
        let has_public = is_dir(sub);
        if prefix.len == 0 {
            if has_app { format(m, pk.name, ": a package without `at` has no app/ folder"); err(manifest, 0, m); continue; }
            if has_public { format(m, pk.name, ": a package without `at` has no public/ folder"); err(manifest, 0, m); continue; }
        } else {
            var clash: u8[>..] = [];
            format(clash, "app/", prefix);
            if is_dir(clash) {
                format(m, pk.name, ": the project has this folder, so the package cannot be mounted at /", prefix);
                err(clash, 0, m);
                continue;
            }
        }
        // A package folder inside the project's own scanned folders would be read twice.
        for own in ["app", "components", "lib", "public"] {
            var ob: u8[>..] = [];
            format(ob, cwd, "/", own);
            var clean: u8[>..] = [];
            clean_path(dir, clean);
            if is_ancestor(ob, clean) {
                format(m, pk.name, ": this package folder is inside the project's ", own, "/ folder; move it elsewhere in the project");
                err(PKG_LIST, ln, m);
                break;
            }
        }
        if m.len > 0 { continue; }
        pkgs.push(pk);
    }
    check_nested_mounts();
}

// A mount B = A + "/rest" inside mount A is allowed when A's package has no app/rest folder.
// The innermost enclosing mount is the one checked; the order of lines does not matter.
fn check_nested_mounts() {
    for b in pkgs {
        if b.mount.len == 0 { continue; }
        var best = -1;
        for a, ai in pkgs {
            if a.mount.len == 0 || a.mount.len >= b.mount.len || !is_ancestor(a.mount, b.mount) { continue; }
            if best < 0 || a.mount.len > pkgs[best].mount.len { best = ai; }
        }
        if best < 0 { continue; }
        let a = pkgs[best];
        let rest = b.mount[a.mount.len + 1..];
        var f: u8[>..] = [];
        format(f, a.dir, "/app/", rest);
        if is_dir(f) {
            var m: u8[>..] = [];
            format(m, b.name, ": mounted at /", b.mount, ", but package ", a.name, " (mounted at /", a.mount, ", ", PKG_LIST, ":", a.line, ") has the folder ", f);
            err(PKG_LIST, b.line, m);
        }
    }
}

// ---------------------------------------------------------------- scan

// base is the app folder ("app", or PKGDIR/app), prefix the mount ("" for the project); rel is relative to base.
fn scan_dir(base: const u8[:], prefix: const u8[:], rel: const u8[:], todo: u8[..512][>..]&) {
    var path: u8[>..] = [];
    path.append(base);
    if rel.len > 0 { path.push('/'); path.append(rel); }
    var full_rel: u8[>..] = [];
    full_rel.append(prefix);
    if prefix.len > 0 && rel.len > 0 { full_rel.push('/'); }
    full_rel.append(rel);
    var names: u8[>..] = [];
    if !list_dir(path, names) { return; }
    var d = Dir { rel: "", root: "", route: false, page_html: false, page_goose: false, layout: false, middleware: false,
                  methods: 0, has_load: false, has_before: false, has_after: false, has_post: false, frags: "",
                  route_ns: "", page_ns: "", layout_ns: "", mw_ns: "" };
    if full_rel.len >= 512 || path.len >= 512 { err(path, 0, "path too long"); return; }
    d.rel.append(full_rel);
    d.root.append(path);
    var subdirs: u8[>..] = [];
    var catch_alls = 0;
    for name in split(names, '\n') {
        if name.len == 0 { continue; }
        var full: u8[>..] = [];
        format(full, path, "/", name);
        if is_dir(full) {
            if name == "__gweb" { err(full, 0, "__gweb is reserved for the health, readiness and metrics URLs; rename this folder"); continue; }
            if name[0] == '_' || name[0] == '.' { continue; }
            if catch_kind(rel) > 0 {
                err(full, 0, "a catch-all folder is the last segment of its route; move this folder out of it");
                continue;
            }
            let kind = seg_kind(name);
            if kind < 0 {
                err(full, 0, "a dynamic segment folder is [name], [...name] or [[...name]], where name is an identifier");
                continue;
            }
            if kind >= 2 {
                catch_alls += 1;
                if catch_alls > 1 { err(full, 0, "a folder holds one catch-all folder at most"); continue; }
            }
            subdirs.append(name);
            subdirs.push('\n');
            continue;
        }
        if name == "route.goose" { d.route = true; }
        else if name == "page.html" { d.page_html = true; }
        else if name == "page.goose" { d.page_goose = true; }
        else if name == "layout.html" { d.layout = true; }
        else if name == "middleware.goose" { d.middleware = true; }
        else if name == "error.html" { d.error_html = true; }
        else if name == "loading.html" { d.loading = true; }
        else if name == "not-found.html" {
            if prefix.len > 0 || base != "app" { err(full, 0, "a package has no not-found.html; the project's app/ owns the 404 page"); }
            else if rel.len == 0 { has_not_found = true; } else { err(full, 0, "not-found.html belongs in app/ only"); }
        }
        else if name == "state.goose" {
            if base != "app" { err(full, 0, "a package has no state.goose; the project's app/ owns the state"); }
            else if rel.len == 0 { has_state = true; } else { err(full, 0, "state.goose belongs in app/ only"); }
        }
        else if name == "config.goose" {
            if rel.len == 0 { has_config = true; } else { err(full, 0, "config.goose belongs in app/ only"); }
        }
        else if name == "socket.goose" {
            if rel.len == 0 { has_socket = true; } else { err(full, 0, "socket.goose belongs in app/ only"); }
        }
        else if name == "sitemap.goose" {
            if rel.len == 0 { has_sitemap = true; } else { err(full, 0, "sitemap.goose belongs in app/ only"); }
        }
        else if name == "jobs.goose" {
            if rel.len == 0 { has_jobs = true; } else { err(full, 0, "jobs.goose belongs in app/ only"); }
        }
    }
    if d.route && d.page_html { err(path, 0, "a folder has route.goose or page.html, not both"); }
    if d.page_goose && !d.page_html { err(path, 0, "page.goose needs a page.html beside it"); }
    let i = dirs.len;
    var n: u8[>..] = [];
    var sl: u8[>..] = [];
    slug(sl, full_rel);
    if d.route { n.clear(); format(n, "r", i); if sl.len > 0 { format(n, "_", sl); } d.route_ns.append(n[..min(n.len, 200)]); }
    if d.page_html { n.clear(); format(n, "p", i); if sl.len > 0 { format(n, "_", sl); } d.page_ns.append(n[..min(n.len, 200)]); }
    if d.layout { n.clear(); format(n, "l", i); d.layout_ns.append(n); }
    if d.middleware { n.clear(); format(n, "m", i); d.mw_ns.append(n); }
    if d.error_html { n.clear(); format(n, "e", i); d.error_ns.append(n); }
    if d.loading { n.clear(); format(n, "g", i); d.loading_ns.append(n); }
    dirs.push(d);
    // Children go on the stack last-first, so they come off in sorted order.
    let subs = split(subdirs, '\n');
    var k = subs.len;
    while k > 0 {
        k -= 1;
        if subs[k].len == 0 { continue; }
        var r: u8[..512] = "";
        if rel.len + subs[k].len + 1 >= 512 { continue; }
        if rel.len > 0 { r.append(rel); r.push('/'); }
        r.append(subs[k]);
        todo.push(r);
    }
}

fn scan_app(base: const u8[:], prefix: const u8[:]) {
    var todo: u8[..512][>..] = [];
    todo.push("");
    while todo.len > 0 {
        let rel: u8[..512] = todo[todo.len - 1];
        todo.pop();
        scan_dir(base, prefix, rel, todo);
    }
}

fn content_type(file: const u8[:]) -> const u8[:] {
    let dot = rfind(file, ".");
    if dot < 0 { return "application/octet-stream"; }
    var ext: u8[..16] = "";
    let e = file[dot + 1..];
    if e.len > 16 { return "application/octet-stream"; }
    ext.append(e);
    to_lower(ext);
    if ext == "html" || ext == "htm" { return "text/html; charset=utf-8"; }
    if ext == "css" { return "text/css; charset=utf-8"; }
    if ext == "js" || ext == "mjs" { return "text/javascript; charset=utf-8"; }
    if ext == "json" || ext == "map" { return "application/json"; }
    if ext == "txt" { return "text/plain; charset=utf-8"; }
    if ext == "xml" { return "application/xml"; }
    if ext == "svg" { return "image/svg+xml"; }
    if ext == "png" { return "image/png"; }
    if ext == "jpg" || ext == "jpeg" { return "image/jpeg"; }
    if ext == "gif" { return "image/gif"; }
    if ext == "webp" { return "image/webp"; }
    if ext == "avif" { return "image/avif"; }
    if ext == "ico" { return "image/x-icon"; }
    if ext == "woff2" { return "font/woff2"; }
    if ext == "woff" { return "font/woff"; }
    if ext == "pdf" { return "application/pdf"; }
    if ext == "wasm" { return "application/wasm"; }
    return "application/octet-stream";
}

fn etag_of(data: const u8[:]) -> u8[..24] {
    var h: u64 = 14695981039346656037;
    for c in data { h = (h ^ c) * 1099511628211; }
    var t: u8[..24] = "\"";
    let hex = "0123456789abcdef";
    for k in 16 { t.push(hex[(h >> ((15 - k) * 4) as u64) & 15]); }
    t.push('"');
    return t;
}

// The hash goes before the last extension of the last path segment; a dot that starts the segment is not an extension.
fn hashed_url(url: const u8[:], etag: const u8[:]) -> u8[..520] {
    var seg = 0;
    for c, i in url { if c == '/' { seg = i + 1; } }
    var dot = -1;
    for i in seg..url.len { if url[i] == '.' && i > seg { dot = i; } }
    var h: u8[..520] = "";
    if dot < 0 { h.append(url); } else { h.append(url[..dot]); }
    h.push('.');
    h.append(etag[1..9]);
    if dot >= 0 { h.append(url[dot..]); }
    return h;
}

// base is the public folder ("public", or PKGDIR/public); prefix the mount; urls start with /prefix.
fn scan_public_dir(base: const u8[:], prefix: const u8[:], rel: const u8[:], todo: u8[..512][>..]&) {
    var path: u8[>..] = [];
    path.append(base);
    if rel.len > 0 { path.push('/'); path.append(rel); }
    var names: u8[>..] = [];
    if !list_dir(path, names) { return; }
    for name in split(names, '\n') {
        if name.len == 0 || name[0] == '.' { continue; }
        var r: u8[>..] = [];
        if rel.len > 0 { format(r, rel, "/"); }
        r.append(name);
        var full: u8[>..] = [];
        format(full, base, "/", r);
        if is_dir(full) { if r.len < 512 { var t: u8[..512] = ""; t.append(r); todo.push(t); } continue; }
        if r.len >= 500 { err(full, 0, "path too long"); continue; }
        var data: u8[>..] = [];
        if !read(full, data) { continue; }
        var s = Static { url: "/", file: "", ctype: "", etag: "", hashed: "", embed: "", min: false, gz: -1 };
        if prefix.len > 0 { s.url.append(prefix); s.url.push('/'); }
        s.url.append(r);
        s.file.append(full);
        s.ctype.append(content_type(name));
        var mined: u8[>..] = [];
        if minify && starts_with(s.ctype, "text/css") && minify_css(data, mined) {
            s.min = true;
            s.etag = etag_of(mined);
        } else {
            s.etag = etag_of(data);
        }
        s.hashed = hashed_url(s.url, s.etag);
        statics.push(s);
    }
}

fn scan_public(base: const u8[:], prefix: const u8[:]) {
    var todo: u8[..512][>..] = [];
    todo.push("");
    while todo.len > 0 {
        let rel: u8[..512] = todo[todo.len - 1];
        todo.pop();
        scan_public_dir(base, prefix, rel, todo);
    }
}

struct Comp { name: u8[..64], path: u8[..512] }

// Adds the components of one folder (the project's components/, or a package's) to found.
fn scan_components_in(dir: const u8[:], found: Comp[>..<]&) {
    var names: u8[>..] = [];
    if !list_dir(dir, names) { return; }
    for f in split(names, '\n') {
        if f.len == 0 || f[0] == '.' || !ends_with(f, ".gshtml") { continue; }
        let n = f[..f.len - 7];
        var ok = n.len > 0 && n.len <= 64 && n[0] >= 'A' && n[0] <= 'Z';
        for c in n { if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) { ok = false; } }
        var p: u8[>..] = [];
        format(p, dir, "/", f);
        if !ok { err(p, 0, "a component's name is [A-Z][A-Za-z0-9]*, as in components/TodoBox.gshtml"); continue; }
        if p.len >= 512 { err(p, 0, "path too long"); continue; }
        var c = Comp { name: "", path: "" };
        c.name.append(n);
        c.path.append(p);
        found.push(c);
    }
}

fn scan_components() {
    component_names.clear();
    component_paths.clear();
    if is_dir("public/_gw") { err("public/_gw", 0, "/_gw/ is gweb's component folder; rename this folder"); }
    var found: Comp[>..<] = [];
    scan_components_in("components", found);
    for pk in pkgs {
        var dir: u8[>..] = [];
        format(dir, pk.dir, "/components");
        scan_components_in(dir, found);
    }
    sort(found) { a, b => compare(a.name, b.name) < 0 || (a.name == b.name && compare(a.path, b.path) < 0) };
    for c, i in found {
        if i > 0 && found[i - 1].name == c.name {
            var m: u8[>..] = [];
            format(m, "component ", c.name, " is also defined in ", found[i - 1].path, "; component names are one flat namespace");
            err(c.path, 0, m);
            continue;
        }
        component_names.push(c.name);
        component_paths.push(c.path);
    }
}

// stores/Name.gshtml: a store's name follows the rule for a component's, and no component has it too.
fn scan_stores() {
    store_names.clear();
    var names: u8[>..] = [];
    if !list_dir("stores", names) { return; }
    var found: u8[..64][>..<] = [];
    for f in split(names, '\n') {
        if f.len == 0 || f[0] == '.' || !ends_with(f, ".gshtml") { continue; }
        let n = f[..f.len - 7];
        var ok = n.len > 0 && n.len <= 64 && n[0] >= 'A' && n[0] <= 'Z';
        for c in n { if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) { ok = false; } }
        var p: u8[>..] = [];
        format(p, "stores/", f);
        if !ok { err(p, 0, "a store's name is [A-Z][A-Za-z0-9]*, as in stores/Cart.gshtml"); continue; }
        if has_component(n) { err(p, 0, "a store and a component cannot have the same name"); continue; }
        var t: u8[..64] = "";
        t.append(n);
        found.push(t);
    }
    sort(found) { a, b => compare(a, b) < 0 };
    for t in found { store_names.push(t); }
}

fn component_index(name: const u8[:]) -> i64 {
    for n, i in component_names { if n == name { return i; } }
    return -1;
}

fn is_reactive_component(name: const u8[:]) -> bool {
    let i = component_index(name);
    return i >= 0 && i < component_reactive.len && component_reactive[i] == 1;
}

fn has_component(name: const u8[:]) -> bool {
    for n in component_names { if n == name { return true; } }
    return false;
}

fn scan() {
    dirs.clear();
    statics.clear();
    errors = 0;
    has_state = false;
    has_state_init = false;
    has_config = false;
    has_sitemap = false;
    has_entries = false;
    has_robots = false;
    has_socket = false;
    has_state_shutdown = false;
    has_jobs = false;
    has_jobs_schedule = false;
    has_not_found = false;
    if !is_dir("app") { err("app", 0, "no app/ folder here; run gweb in a project, or gweb new <dir>"); return; }
    load_packages();
    if errors > 0 { return; }
    scan_app("app", "");
    scan_public("public", "");
    let own_statics = statics.len;
    for pk in pkgs {
        if pk.mount.len == 0 { continue; }
        var base: u8[>..] = [];
        format(base, pk.dir, "/app");
        if is_dir(base) { scan_app(base, pk.mount); }
        base.clear();
        format(base, pk.dir, "/public");
        if is_dir(base) { scan_public(base, pk.mount); }
    }
    for a, ai in statics {
        if ai < own_statics { continue; }
        for bi in ai {
            if statics[bi].url != a.url { continue; }
            var m: u8[>..] = [];
            format(m, "this file has the same URL as ", statics[bi].file);
            err(a.file, 0, m);
        }
    }
    scan_components();
    scan_stores();
    // A public file may not shadow a route at the same literal URL.
    for d in dirs {
        if !d.route && !d.page_html { continue; }
        var u: u8[>..] = [];
        url_of(u, d.rel);
        for s in statics { if s.url == u { err(s.file, 0, "this file has the same URL as a route"); } }
    }
    check_route_shapes();
    if has_sitemap {
        if has_static("/sitemap.xml") { err("app/sitemap.goose", 0, "public/sitemap.xml exists; remove it, or remove app/sitemap.goose, which generates /sitemap.xml"); }
        for d in dirs {
            if !d.route && !d.page_html { continue; }
            if d.rel != "sitemap.xml" && d.rel != "robots.txt" { continue; }
            var path: u8[>..] = [];
            app_path(path, d, "");
            path.pop();
            var m: u8[>..] = [];
            format(m, "/", d.rel, " is generated by app/sitemap.goose; remove this folder", if d.rel == "robots.txt" { " or add public/robots.txt" } else { "" });
            err(path, 0, m);
        }
    }
}

fn check_route_shapes() {
    for d in dirs {
        if !d.route && !d.page_html { continue; }
        var path: u8[>..] = [];
        app_path(path, d, "");
        if path[path.len - 1] == '/' { path.pop(); }
        let segs = split(d.rel, '/');
        if segs.len > 16 { err(path, 0, "a route is at most 16 folders deep"); }
        let kind = catch_kind(d.rel);
        if kind == 0 { continue; }
        let name = catch_name(last_seg(d.rel));
        for k in segs.len - 1 {
            if seg_kind(segs[k]) == 1 && segs[k][1..segs[k].len - 1] == name {
                var m: u8[>..] = [];
                format(m, "the catch-all name ", name, " is already a parameter of this path");
                err(path, 0, m);
            }
        }
        if kind == 3 {
            let parent = parent_of(d.rel);
            for p in dirs {
                if p.rel != parent || (!p.route && !p.page_html) { continue; }
                var pp: u8[>..] = [];
                app_path(pp, p, "");
                if pp[pp.len - 1] == '/' { pp.pop(); }
                var u: u8[>..] = [];
                url_of(u, parent);
                var m: u8[>..] = [];
                format(m, path, " and ", pp, " both answer ", u, "; use [...", name, "] or remove one");
                err(path, 0, m);
            }
        }
    }
}

// ---------------------------------------------------------------- copies

fn copy_prefixed(src: const u8[:], ns: const u8[:], code: u8[>..]&) -> bool {
    return copy_prefixed_forms(src, ns, code, false);
}

// forms: a page.goose or route.goose, whose struct <Name>Form gets a generated fn decode after the user's last line.
fn copy_prefixed_forms(src: const u8[:], ns: const u8[:], code: u8[>..]&, forms: bool) -> bool {
    if !read(src, code) { return false; }
    for line, i in split(code, '\n') {
        if starts_with(trim_start(line), "namespace ") {
            err(src, i + 1, "app files get their namespace from gweb; remove this line");
            return false;
        }
    }
    if imports_sqlite(code) { uses_sqlite = true; }
    var extra: u8[>..] = [];
    if forms { form_decoders(src, code, extra); }
    if mentions_keys(code) { uses_keys = true; }
    var out: u8[>..] = [];
    format(out, "namespace ", ns, "; ");
    if extra.len > 0 {
        // On line 1, so the user's line numbers stay the same.
        var have: u8[>..] = [];
        imports_of(code, have);
        if find(have, "import gweb.forms.valid;") < 0 { out.append("import gweb.forms.valid; "); }
        if find(have, "import gweb.forms.upload;") < 0 { out.append("import gweb.forms.upload; "); }
    }
    out.append(code);
    out.append(extra);
    var dst: u8[>..] = [];
    format(dst, gen_root, "/", ns, ".goose");
    write(dst, out);
    format(map_text, ns, ".goose\t", src, "\n");
    format(srcmap_text, "file ", ns, ".goose ", src, "\n");
    // Line 1 follows the namespace prefix; empty lines map to column 0 without a record.
    let prefix = ns.len + 12;
    for line, i in split(code, '\n') {
        if i == 0 { format(srcmap_text, "L 1 1 0:0:0 ", prefix, ":0:", line.len, "\n"); }
        else if line.len > 0 { format(srcmap_text, "L ", i + 1, " ", i + 1, " 0:0:", line.len, "\n"); }
    }
    return true;
}

fn ident_byte(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

// The name when t starts `struct <Name>Form {` (Name at least one character), else "".
fn form_struct_name(t: const u8[:]) -> const u8[:] {
    if !starts_with(t, "struct ") { return ""; }
    let r = trim_start(t[7..]);
    var n = 0;
    while n < r.len && ident_byte(r[n]) { n += 1; }
    if n <= 4 || !ends_with(r[..n], "Form") { return ""; }
    let rest = trim_start(r[n..]);
    if rest.len == 0 || rest[0] != '{' { return ""; }
    return r[..n];
}

// True for u8[..N], where N is a number or a name.
fn is_text_type(ty: const u8[:]) -> bool {
    if !starts_with(ty, "u8[..") || !ends_with(ty, "]") || ty.len <= 6 { return false; }
    let n = ty[5..ty.len - 1];
    for c in n { if !ident_byte(c) { return false; } }
    return true;
}

// One `name: type = default` field: checks the type and appends its decoder statement to body.
fn form_field(src: const u8[:], line: i64, text: const u8[:], body: u8[>..]&) {
    let t = trim(text);
    if t.len == 0 { return; }
    let colon = find(t, ":");
    if colon <= 0 { err(src, line, "form fields are u8[..N], i64, bool or gweb::Upload"); return; }
    let name = trim(t[..colon]);
    let rest = trim_start(t[colon + 1..]);
    let eq = find(rest, "=");
    let ty = trim(if eq >= 0 { rest[..eq] } else { rest });
    let required = if eq >= 0 { "false" } else { "true" };
    if !is_ident(name) { err(src, line, "form fields are u8[..N], i64, bool or gweb::Upload"); return; }
    if is_text_type(ty) { format(body, "    gweb::form_text(req, \"", name, "\", f.", name, ", errs, ", required, ");\n"); }
    else if ty == "i64" { format(body, "    gweb::form_int(req, \"", name, "\", f.", name, ", errs, ", required, ");\n"); }
    else if ty == "bool" { format(body, "    gweb::form_bool(req, \"", name, "\", f.", name, ");\n"); }
    else if ty == "gweb::Upload" { format(body, "    gweb::form_upload(ctx, \"", name, "\", f.", name, ", errs, ", required, ");\n"); }
    else { err(src, line, "form fields are u8[..N], i64, bool or gweb::Upload"); }
}

// Finds each `struct <Name>Form {`, checks its fields and appends one fn decode per struct to extra.
// A user fn decode( is an error. Nothing is appended when the file has no form struct.
fn form_decoders(src: const u8[:], code: const u8[:], extra: u8[>..]&) {
    let lines = split(code, '\n');
    var first_form: u8[>..] = [];
    var k = 0;
    while k < lines.len {
        let name = form_struct_name(trim_start(lines[k]));
        if name.len == 0 { k += 1; continue; }
        if extra.len == 0 { extra.append("\n// gweb: form decoders (generated)\n"); first_form.append(name); }
        var body: u8[>..] = [];
        var cur: u8[>..] = [];
        var cur_line = 0;
        var depth = 0;
        var in_str = false;
        var done = false;
        var ln = k;
        var start = find(lines[k], "{") + 1;
        while ln < lines.len && !done {
            let line = lines[ln];
            var ci = start;
            while ci < line.len {
                let c = line[ci];
                if in_str {
                    cur.push(c);
                    if c == '\\' && ci + 1 < line.len { ci += 1; cur.push(line[ci]); }
                    else if c == '"' { in_str = false; }
                    ci += 1;
                    continue;
                }
                if c == '/' && ci + 1 < line.len && line[ci + 1] == '/' { break; }
                if depth == 0 && c == '}' { done = true; break; }
                if depth == 0 && c == ',' {
                    form_field(src, cur_line, cur, body);
                    cur.clear();
                    cur_line = 0;
                    ci += 1;
                    continue;
                }
                if c == '"' { in_str = true; }
                if c == '[' || c == '(' || c == '{' { depth += 1; }
                if c == ']' || c == ')' || c == '}' { depth -= 1; }
                if cur_line == 0 && c != ' ' && c != '\t' { cur_line = ln + 1; }
                cur.push(c);
                ci += 1;
            }
            if !done { cur.push(' '); }
            start = 0;
            ln += 1;
        }
        form_field(src, cur_line, cur, body);
        if !done { err(src, k + 1, "this struct is never closed with }"); }
        format(extra, "fn decode(req: const http::Request&, ctx: const gweb::Ctx&, f: ", name, "&, errs: gweb::FieldErrors&) -> bool {\n");
        extra.append("    let before = errs.n;\n");
        extra.append(body);
        extra.append("    return errs.n == before;\n}\n");
        k = ln;
    }
    if extra.len == 0 { return; }
    for line, i in split(code, '\n') {
        if starts_with(trim_start(line), "fn decode(") {
            var m: u8[>..] = [];
            format(m, "fn decode is generated for ", first_form, "; rename yours");
            err(src, i + 1, m);
            return;
        }
    }
}

// True when a line of code starts const MAX_UPLOAD.
fn max_upload_const(code: const u8[:]) -> bool {
    for line in split(code, '\n') {
        let t = trim_start(line);
        if starts_with(t, "const MAX_UPLOAD") && (t.len == 16 || !ident_byte(t[16])) { return true; }
    }
    return false;
}

fn imports_sqlite(code: const u8[:]) -> bool {
    for line in split(code, '\n') { if find(line, "import sqlite;") >= 0 && starts_with(trim(line), "import") { return true; } }
    return false;
}

fn scan_lib_for_sqlite(root: const u8[:]) {
    var todo: u8[..512][>..] = [];
    var first: u8[..512] = "";
    first.append(root);
    todo.push(first);
    while todo.len > 0 {
        let dir: u8[..512] = todo[todo.len - 1];
        todo.pop();
        var names: u8[>..] = [];
        if !list_dir(dir, names) { continue; }
        for name in split(names, '\n') {
            if name.len == 0 || name[0] == '.' { continue; }
            var full: u8[>..] = [];
            format(full, dir, "/", name);
            if is_dir(full) {
                if full.len < 512 { var t: u8[..512] = ""; t.append(full); todo.push(t); }
            } else if ends_with(name, ".goose") {
                var code: u8[>..] = [];
                if read_file(full, code) {
                    if imports_sqlite(code) { uses_sqlite = true; }
                    if mentions_keys(code) { uses_keys = true; }
                }
            }
        }
    }
}

// The hub (one extra thread and its sockets) is built only for apps that use it.
fn scan_for_hub(root: const u8[:]) {
    var todo: u8[..512][>..] = [];
    var first: u8[..512] = "";
    first.append(root);
    todo.push(first);
    while todo.len > 0 && !uses_hub {
        let dir: u8[..512] = todo[todo.len - 1];
        todo.pop();
        var names: u8[>..] = [];
        if !list_dir(dir, names) { continue; }
        for name in split(names, '\n') {
            if name.len == 0 || name[0] == '.' { continue; }
            var full: u8[>..] = [];
            format(full, dir, "/", name);
            if is_dir(full) {
                if full.len < 512 { var t: u8[..512] = ""; t.append(full); todo.push(t); }
            } else if ends_with(name, ".goose") {
                var code: u8[>..] = [];
                if read_file(full, code) && (find(code, "gweb::subscribe(") >= 0 || find(code, "gweb::websocket(") >= 0) { uses_hub = true; }
            }
        }
    }
}

fn imports_of(src: const u8[:], out: u8[>..]&) {
    for line in split(src, '\n') {
        let t = trim(line);
        if starts_with(t, "import ") { out.append(t); out.push(' '); }
    }
}

fn add_default_imports(imports: u8[>..]&) {
    for imp in ["import std;", "import net.http;", "import gweb;", "import gweb.site.template;", "import gweb.forms.valid;", "import gweb.site.meta;"] {
        if find(imports, imp) < 0 { imports.append(imp); imports.push(' '); }
    }
    for n in component_names {
        var imp: u8[>..] = [];
        format(imp, "import ", n, ";");
        if find(imports, imp) < 0 { imports.append(imp); imports.push(' '); }
    }
    if has_locales && find(imports, "import t;") < 0 { imports.append("import t; "); }
    for n in store_names {
        var imp: u8[>..] = [];
        format(imp, "import ", n, ";");
        if find(imports, imp) < 0 { imports.append(imp); imports.push(' '); }
    }
}

// ---------------------------------------------------------------- templates

fn frag_name_ok(s: const u8[:]) -> bool {
    if s.len == 0 || s.len > 64 { return false; }
    for c, i in s {
        let alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        let more = (c >= '0' && c <= '9') || c == '_' || c == '-';
        if !alpha && !(more && i > 0) { return false; }
    }
    return true;
}

fn count_names(names: const u8[:]) -> i64 {
    if names.len == 0 { return 0; }
    var n = 1;
    for c in names { if c == ' ' { n += 1; } }
    return n;
}

fn has_name(names: const u8[:], name: const u8[:]) -> bool {
    if names.len == 0 { return false; }
    for n in split(names, ' ') { if n == name { return true; } }
    return false;
}

// Source maps (DESIGN-ADDENDUM-18, D1): the column in out of the next byte, a segment
// "gcol:scol:len", and the width of the whitespace trim() takes off the front.
fn out_col(out: const u8[:]) -> i64 {
    var i = out.len;
    while i > 0 && out[i - 1] != '\n' { i -= 1; }
    return out.len - i;
}

fn seg_add(segs: u8[>..]&, gcol: i64, scol: i64, len: i64) {
    format(segs, " ", gcol, ":", scol, ":", len);
}

fn lead_ws(s: const u8[:]) -> i64 {
    var n = 0;
    while n < s.len && ws(s[n]) { n += 1; }
    return n;
}

// Copy trim(rest) to out; scol is where rest starts in the source line.
fn put_expr(out: u8[>..]&, segs: u8[>..]&, rest: const u8[:], scol: i64) {
    let x = trim(rest);
    seg_add(segs, out_col(out), scol + lead_ws(rest), x.len);
    out.append(x);
}

fn template_fragment_open(path: const u8[:], ln: i64, name: const u8[:], line: const u8[:], at: i64, kind: i64,
                          stack: u8[>..]&, stack_lines: i64[>..]&, frags: u8[>..]&, out: u8[>..]&) {
    let k = count_names(frags) + 1;
    if kind != K_PAGE { err(path, ln, "{#fragment} is for page.html only"); }
    else if !frag_name_ok(name) { err(path, ln, "a fragment name is [A-Za-z][A-Za-z0-9_-]*, at most 64 bytes"); }
    else {
        if stack.len > 0 { err(path, ln, "{#fragment} cannot be inside {#if}, {#for} or another {#fragment}"); }
        var ok = false;
        let before = line[..at];
        if before.len > 0 && before[before.len - 1] == '>' {
            var lt = before.len - 1;
            while lt > 0 && before[lt] != '<' { lt -= 1; }
            var want: u8[>..] = [];
            format(want, "id=\"", name, "\"");
            // id="NAME" must start an attribute, so data-id="NAME" does not count.
            var from = lt;
            while before[lt] == '<' && !ok {
                let k2 = find(before[from..], want);
                if k2 < 0 { break; }
                let p = from + k2;
                if p > 0 && (before[p - 1] == ' ' || before[p - 1] == '\t') { ok = true; }
                from = p + 1;
            }
        }
        if !ok {
            var m: u8[>..] = [];
            format(m, "{#fragment ", name, "} goes right after the opening tag that has id=\"", name, "\", on the same line");
            err(path, ln, m);
        }
        if has_name(frags, name) {
            var m: u8[>..] = [];
            format(m, "two fragments named ", name);
            err(path, ln, m);
        } else if k > 8 { err(path, ln, "a page has at most 8 fragments"); }
        else { if frags.len > 0 { frags.push(' '); } frags.append(name); }
    }
    stack.push('g'); stack_lines.push(ln);
    format(out, "} if gw_part == 0 || gw_part == ", k, " { ");
}

fn template_fragment_close(path: const u8[:], ln: i64, rest: const u8[:], kind: i64,
                           stack: u8[>..]&, stack_lines: i64[>..]&, out: u8[>..]&) {
    if kind != K_PAGE { err(path, ln, "{#fragment} is for page.html only"); }
    else if stack.len == 0 || stack[stack.len - 1] != 'g' { err(path, ln, "{/fragment} does not close an open {#fragment}"); }
    else {
        stack.pop(); stack_lines.pop();
        if !starts_with(rest, "</") { err(path, ln, "{/fragment} goes right before the closing tag of the element"); }
    }
    out.append("} if gw_part == 0 { ");
}

fn template_tag(path: const u8[:], ln: i64, inner: const u8[:], line: const u8[:], at: i64, end: i64, kind: i64,
                stack: u8[>..]&, stack_lines: i64[>..]&, frags: u8[>..]&, out: u8[>..]&, segs: u8[>..]&) {
    let b = at + 1 + lead_ws(line[at + 1..end]);   // where inner starts in line
    if inner == "#fragment" || starts_with(inner, "#fragment ") {
        template_fragment_open(path, ln, trim(inner[9..]), line, at, kind, stack, stack_lines, frags, out);
    } else if inner == "/fragment" {
        template_fragment_close(path, ln, line[end + 1..], kind, stack, stack_lines, out);
    } else if starts_with(inner, "#if ") {
        out.append("if ");
        put_expr(out, segs, inner[4..], b + 4);
        out.append(" { ");
        stack.push('i'); stack_lines.push(ln);
    } else if starts_with(inner, "#else if ") {
        if stack.len == 0 || stack[stack.len - 1] != 'i' { err(path, ln, "{#else if} outside {#if}"); }
        out.append("} else if ");
        put_expr(out, segs, inner[9..], b + 9);
        out.append(" { ");
    } else if inner == "#else" {
        if stack.len == 0 || stack[stack.len - 1] != 'i' { err(path, ln, "{#else} outside {#if}"); }
        out.append("} else { ");
    } else if starts_with(inner, "#for ") {
        let body = trim(inner[5..]);
        if find(body, " in ") < 0 { err(path, ln, "{#for x in e} or {#for x, i in e}"); }
        out.append("for ");
        put_expr(out, segs, inner[5..], b + 5);
        out.append(" { ");
        stack.push('f'); stack_lines.push(ln);
    } else if starts_with(inner, "#let ") {
        out.append("let ");
        put_expr(out, segs, inner[5..], b + 5);
        out.append("; ");
    } else if inner == "#else if" {
        err(path, ln, "{#else if e} needs an expression");
    } else if inner == "#for" {
        err(path, ln, "{#for x in e} or {#for x, i in e}");
    } else if inner == "#let" {
        err(path, ln, "{#let n = e} needs a name and a value");
    } else if inner == "#raw" || inner == "#if" {
        var m: u8[>..] = [];
        format(m, "{", inner, " e} needs an expression");
        err(path, ln, m);
    } else if starts_with(inner, "#raw ") {
        out.append("gweb::raw(out, ");
        put_expr(out, segs, inner[5..], b + 5);
        out.append("); ");
    } else if inner == "/if" || inner == "/for" {
        let want: u8 = if inner == "/if" { 'i' } else { 'f' };
        if stack.len == 0 || stack[stack.len - 1] != want {
            var m: u8[>..] = [];
            format(m, "{", inner, "} does not close an open {#", inner[1..], "}");
            err(path, ln, m);
        } else { stack.pop(); stack_lines.pop(); }
        out.append("} ");
    } else if starts_with(inner, "#") || starts_with(inner, "/") {
        var m: u8[>..] = [];
        format(m, "unknown tag {", inner, "}");
        err(path, ln, m);
    } else {
        if inner.len == 0 { err(path, ln, "empty { }"); }
        out.append("gweb::put(out, ");
        put_expr(out, segs, inner, b);
        out.append("); ");
    }
}

let GW_PRELOAD = "<link rel=\"modulepreload\" href=\"/_gw/gwi.js\">";
let GW_FRAG = "<script type=\"module\" src=\"/_gw/gwf.js\"></script>";
let GW_TRANS = "<script type=\"module\" src=\"/_gw/gwt.js\"></script>";
let GW_SSE = "<script type=\"module\" src=\"/_gw/gwe.js\"></script>";
let GW_NAV = "<script type=\"module\" src=\"/_gw/gwn.js\"></script>";

// The module tags of the template being compiled: gwf.js for gw-target, gwn.js for <body gw-boost>.
fn script_tag(out: u8[>..]&) {
    var t: u8[>..] = [];
    t.append(GW_PRELOAD);
    if tpl_script { t.append(GW_FRAG); }
    if tpl_boost { t.append(GW_NAV); }
    if tpl_trans { t.append(GW_TRANS); }
    if tpl_sse { t.append(GW_SSE); }
    out.append("out.append(\""); lit(out, t); out.append("\"); ");
}

// Whether a <body ...> tag of src carries gw-boost.
fn has_boost(src: const u8[:]) -> bool {
    var from = 0;
    while from < src.len {
        let k = find(src[from..], "<body");
        if k < 0 { return false; }
        let rest = src[from + k + 5..];
        if rest.len == 0 { return false; }
        let c = rest[0];
        if c == ' ' || c == '\n' || c == '\t' || c == '>' || c == '\r' {
            let e = find(rest, ">");
            let tag = if e < 0 { rest } else { rest[..e] };
            if find(tag, "gw-boost") >= 0 { return true; }
        }
        from = from + k + 5;
    }
    return false;
}

// The start and end of each argument of a call: the pieces between its top-level commas.
fn split_call_args(args: const u8[:], starts: i64[>..]&, ends: i64[>..]&) {
    var depth = 0;
    var from = 0;
    var i = 0;
    while i < args.len {
        let c = args[i];
        if c == '"' || c == '\'' {
            let j = tscan::skip_literal(args, i);
            if j > i { i = j; continue; }
        }
        if c == '(' || c == '[' || c == '{' { depth += 1; }
        else if c == ')' || c == ']' || c == '}' { depth -= 1; }
        else if c == ',' && depth == 0 {
            starts.push(from);
            ends.push(i);
            from = i + 1;
        }
        i += 1;
    }
    starts.push(from);
    ends.push(args.len);
}

// The length of a leading `name:` (one colon, not ::) in arg, or 0 when arg is not a named argument.
fn named_arg_len(arg: const u8[:]) -> i64 {
    var i = 0;
    if arg.len == 0 || !tscan::ident_start(arg[0]) { return 0; }
    while i < arg.len && tscan::ident_char(arg[i]) { i += 1; }
    let n = i;
    while i < arg.len && (arg[i] == ' ' || arg[i] == '\t') { i += 1; }
    if i < arg.len && arg[i] == ':' && !(i + 1 < arg.len && arg[i + 1] == ':') { return n; }
    return 0;
}

// @Name(a: e1, b: e2) for a reactive component: { let gw_p = Name::Props { a: e1, b: e2, c: DEFAULT }; Name::component(out, gw_p); }
fn reactive_call(path: const u8[:], ln: i64, name: const u8[:], args: const u8[:], out: u8[>..]&) {
    var mine: u8[>..] = [];                 // `prop\tdefault\n` for this component, in declaration order
    for l in split(component_props, '\n') {
        if l.len <= name.len + 1 || !starts_with(l, name) || l[name.len] != '\t' { continue; }
        mine.append(l[name.len + 1..]);
        mine.push('\n');
    }
    let props = split(mine, '\n');
    var np = 0;
    for l in props { if l.len > 0 { np += 1; } }
    var vals: u8[>..] = [];                 // the values given, one after the other
    var vs: i64[>..] = [];                  // where each prop's value starts and ends in vals, or -1
    var ve: i64[>..] = [];
    for k in np { vs.push(-1); ve.push(-1); }
    var starts: i64[>..] = [];
    var ends: i64[>..] = [];
    split_call_args(args, starts, ends);
    let before = errors;
    for pi in starts.len {
        let part = args[starts[pi]..ends[pi]];
        let arg = trim(part);
        if arg.len == 0 {
            if starts.len > 1 && pi + 1 < starts.len { err(path, ln, "an empty argument; write @Name(a: 1, b: 2)"); }
            continue;
        }
        let nlen = named_arg_len(arg);
        if nlen == 0 {
            var m: u8[>..] = [];
            var first: u8[>..] = [];
            if np > 0 { first.append(props[0][..find(props[0], "\t")]); } else { first.append("x"); }
            format(m, "@", name, " takes named props: @", name, "(", first, ": 3)");
            err(path, ln, m);
            return;
        }
        let pname = arg[..nlen];
        var found = -1;
        for k in np {
            let l = props[k];
            if l[..find(l, "\t")] == pname { found = k; }
        }
        var m: u8[>..] = [];
        if found < 0 {
            format(m, name, " has no prop ", pname);
            err(path, ln, m);
            continue;
        }
        if vs[found] >= 0 {
            format(m, "@", name, " passes prop ", pname, " twice");
            err(path, ln, m);
            continue;
        }
        let colon = find(arg, ":");
        let value = trim(arg[colon + 1..]);
        if value.len == 0 {
            format(m, "@", name, " prop ", pname, " needs a value");
            err(path, ln, m);
            continue;
        }
        vs[found] = vals.len;
        vals.append(value);
        ve[found] = vals.len;
    }
    var call: u8[>..] = [];
    format(call, "{ let gw_p = ", name, "::Props { ");
    for k in np {
        let l = props[k];
        let tab = find(l, "\t");
        let pname = l[..tab];
        let dflt = l[tab + 1..];
        if k > 0 { call.append(", "); }
        if vs[k] >= 0 { format(call, pname, ": ", vals[vs[k]..ve[k]]); }
        else if dflt.len > 0 { format(call, pname, ": ", dflt); }
        else {
            var m: u8[>..] = [];
            format(m, "@", name, " needs prop ", pname);
            err(path, ln, m);
            format(call, pname, ": 0");
        }
    }
    if np == 0 { call.append(".. "); }
    // A temporary cannot bind to the const Props& parameter, so the props get a name first.
    format(call, "}; ", name, "::component(out, gw_p); } ");
    if errors == before { out.append(call); }
}

// -1, after reporting the error, when no public file has this URL.
fn static_index(path: const u8[:], ln: i64, want: const u8[:]) -> i64 {
    for s, i in statics { if s.url == want { return i; } }
    var m: u8[>..] = [];
    format(m, "no public file at ", want, " (looked for public/", if want.len > 0 && want[0] == '/' { want[1..] } else { want }, ")");
    err(path, ln, m);
    return -1;
}

// A string literal with no escapes, as the whole of arg; its text, or "" and false.
fn plain_literal(arg: const u8[:]) -> const u8[:], bool {
    if arg.len < 2 || arg[0] != '"' || arg[arg.len - 1] != '"' || find(arg[1..arg.len - 1], "\"") >= 0 || find(arg, "\\") >= 0 { return "", false; }
    return arg[1..arg.len - 1], true;
}

// The hashed URL is written at build time, so a missing file fails the build instead of 404ing.
fn asset_call(path: const u8[:], ln: i64, args: const u8[:], out: u8[>..]&) {
    let want, ok = plain_literal(args);
    if !ok {
        err(path, ln, "@asset() takes one string literal, as in @asset(\"/css/site.css\")");
        return;
    }
    let i = static_index(path, ln, want);
    if i >= 0 { out.append("out.append(\""); lit(out, statics[i].hashed); out.append("\"); "); }
}

// ---------------------------------------------------------------- image sizes

fn img_byte(d: const u8[:], i: i64) -> i64 { if i < 0 || i >= d.len { return 0; } return d[i]; }
fn img_be(d: const u8[:], at: i64, n: i64) -> i64 {
    var v = 0;
    for k in n { v = v * 256 + img_byte(d, at + k); }
    return v;
}
fn img_le(d: const u8[:], at: i64, n: i64) -> i64 {
    var v = 0;
    for k in n { v = v * 256 + img_byte(d, at + n - 1 - k); }
    return v;
}
fn img_space(c: u8) -> bool { c == ' ' || c == '\t' || c == '\n' || c == '\r' }

// A length of digits, an optional fraction and an optional px unit; rounded to whole pixels. Any other unit is not a pixel size.
fn svg_dim(v: const u8[:]) -> i64, bool {
    let t = trim(v);
    var i = 0;
    var whole = 0;
    while i < t.len && t[i] >= '0' && t[i] <= '9' { whole = whole * 10 + (t[i] - '0'); i += 1; }
    var digits = i;
    if i < t.len && t[i] == '.' {
        i += 1;
        if i < t.len && t[i] >= '0' && t[i] <= '9' { if t[i] >= '5' { whole += 1; } digits += 1; }
        while i < t.len && t[i] >= '0' && t[i] <= '9' { i += 1; digits += 1; }
    }
    if digits == 0 { return 0, false; }
    if i < t.len && !(t[i..] == "px") { return 0, false; }
    return whole, whole > 0;
}

// The value of attribute name in an <svg ...> tag, or "". A name inside another (stroke-width) is skipped by requiring space before it.
fn svg_attr(tag: const u8[:], name: const u8[:]) -> const u8[:] {
    var pos = 0;
    while pos < tag.len {
        let k = find(tag[pos..], name);
        if k < 0 { return ""; }
        let at = pos + k;
        pos = at + name.len;
        if at == 0 || !img_space(tag[at - 1]) { continue; }
        var j = pos;
        while j < tag.len && img_space(tag[j]) { j += 1; }
        if j >= tag.len || tag[j] != '=' { continue; }
        j += 1;
        while j < tag.len && img_space(tag[j]) { j += 1; }
        if j >= tag.len || (tag[j] != '"' && tag[j] != '\'') { continue; }
        let q = tag[j];
        var e = j + 1;
        while e < tag.len && tag[e] != q { e += 1; }
        if e >= tag.len { return ""; }
        return tag[j + 1..e];
    }
    return "";
}

fn svg_size(d: const u8[:]) -> i64, i64, bool {
    let at = find(d, "<svg");
    if at < 0 { return 0, 0, false; }
    var end = at;
    var quote: u8 = 0;
    while end < d.len {
        let c = d[end];
        if quote != 0 { if c == quote { quote = 0; } }
        else if c == '"' || c == '\'' { quote = c; }
        else if c == '>' { break; }
        end += 1;
    }
    let tag = d[at..end];
    let w, wok = svg_dim(svg_attr(tag, "width"));
    let h, hok = svg_dim(svg_attr(tag, "height"));
    if wok && hok { return w, h, true; }
    // viewBox is "min-x min-y width height", separated by spaces or commas.
    let vb = svg_attr(tag, "viewBox");
    var n = 0;
    var vw = 0;
    var vh = 0;
    var vok = true;
    var i = 0;
    while i < vb.len {
        while i < vb.len && (img_space(vb[i]) || vb[i] == ',') { i += 1; }
        var j = i;
        while j < vb.len && !img_space(vb[j]) && vb[j] != ',' { j += 1; }
        if j > i {
            if n == 2 { let x, ok = svg_dim(vb[i..j]); vw = x; vok = vok && ok; }
            if n == 3 { let x, ok = svg_dim(vb[i..j]); vh = x; vok = vok && ok; }
            n += 1;
        }
        i = j;
    }
    if n == 4 && vok { return vw, vh, true; }
    return 0, 0, false;
}

// Reads the pixel size from the file's header; false for an unknown format or a truncated file.
fn image_size(d: const u8[:]) -> i64, i64, bool {
    if d.len >= 24 && img_be(d, 0, 4) == 2303741511 && img_be(d, 4, 4) == 218765834 && d[12..16] == "IHDR" {
        let w = img_be(d, 16, 4);
        let h = img_be(d, 20, 4);
        return w, h, w > 0 && h > 0;
    }
    if d.len >= 10 && (starts_with(d, "GIF87a") || starts_with(d, "GIF89a")) {
        let w = img_le(d, 6, 2);
        let h = img_le(d, 8, 2);
        return w, h, w > 0 && h > 0;
    }
    if d.len >= 4 && img_byte(d, 0) == 255 && img_byte(d, 1) == 216 {
        var i = 2;
        while i + 4 <= d.len {
            if d[i] != 255 { i += 1; continue; }
            let m = img_byte(d, i + 1);
            if m == 255 { i += 1; continue; }
            // Markers with no length: TEM, RSTn, SOI, and a stuffed zero.
            if m == 0 || m == 1 || m == 216 || (m >= 208 && m <= 215) { i += 2; continue; }
            if m == 217 { break; }
            let seg = img_be(d, i + 2, 2);
            if seg < 2 { break; }
            if m >= 192 && m <= 207 && m != 196 && m != 200 && m != 204 {
                if i + 9 > d.len { break; }
                let h = img_be(d, i + 5, 2);
                let w = img_be(d, i + 7, 2);
                return w, h, w > 0 && h > 0;
            }
            i += 2 + seg;
        }
        return 0, 0, false;
    }
    if d.len >= 30 && starts_with(d, "RIFF") && d[8..12] == "WEBP" {
        let kind = d[12..16];
        if kind == "VP8 " && img_byte(d, 23) == 157 && img_byte(d, 24) == 1 && img_byte(d, 25) == 42 {
            let w = img_le(d, 26, 2) & 16383;
            let h = img_le(d, 28, 2) & 16383;
            return w, h, w > 0 && h > 0;
        }
        if kind == "VP8L" && img_byte(d, 20) == 47 {
            let b = img_le(d, 21, 4);
            return (b & 16383) + 1, ((b >> 14) & 16383) + 1, true;
        }
        if kind == "VP8X" {
            return img_le(d, 24, 3) + 1, img_le(d, 27, 3) + 1, true;
        }
        return 0, 0, false;
    }
    return svg_size(d);
}

// ---------------------------------------------------------------- @image

// Where the top-level comma after from is, or args.len: quotes and brackets hide the commas inside them.
fn arg_end(args: const u8[:], from: i64) -> i64 {
    var depth = 0;
    var i = from;
    while i < args.len {
        let c = args[i];
        if c == '"' || c == '\'' {
            let j = tscan::skip_literal(args, i);
            if j > i { i = j; continue; }
        }
        if c == '(' || c == '[' || c == '{' { depth += 1; }
        else if c == ')' || c == ']' || c == '}' { depth -= 1; }
        else if c == ',' && depth == 0 { return i; }
        i += 1;
    }
    return args.len;
}

// The text of a string literal, with \" \\ \n \t decoded; false when arg is not exactly one literal.
fn decode_literal(arg: const u8[:], out: u8[>..]&) -> bool {
    if arg.len < 2 || arg[0] != '"' || tscan::skip_literal(arg, 0) != arg.len || arg[arg.len - 1] != '"' { return false; }
    var i = 1;
    while i < arg.len - 1 {
        let c = arg[i];
        if c == '\\' && i + 1 < arg.len - 1 {
            i += 1;
            out.push(if arg[i] == 'n' { '\n' } else if arg[i] == 't' { '\t' } else { arg[i] });
        } else { out.push(c); }
        i += 1;
    }
    return true;
}

// True when attrs sets the attribute name: it starts a word and is followed by = or a space or the end.
fn sets_attr(attrs: const u8[:], name: const u8[:]) -> bool {
    var pos = 0;
    while pos < attrs.len {
        let k = find(attrs[pos..], name);
        if k < 0 { return false; }
        let at = pos + k;
        let e = at + name.len;
        pos = e;
        if (at == 0 || img_space(attrs[at - 1])) && (e == attrs.len || attrs[e] == '=' || img_space(attrs[e])) { return true; }
    }
    return false;
}

// name.ext becomes name@2x.ext; "" when the last segment has no extension.
fn retina_url(url: const u8[:]) -> u8[..520] {
    var seg = 0;
    for c, i in url { if c == '/' { seg = i + 1; } }
    var dot = -1;
    for i in seg..url.len { if url[i] == '.' && i > seg { dot = i; } }
    var r: u8[..520] = "";
    if dot < 0 || url.len + 3 > 512 { return r; }
    r.append(url[..dot]);
    r.append("@2x");
    r.append(url[dot..]);
    return r;
}

fn image_call(path: const u8[:], ln: i64, args: const u8[:], out: u8[>..]&) {
    let usage = "@image() needs a string literal path and an alt text, as in @image(\"/img/a.png\", \"A\")";
    var starts: i64[>..] = [];
    var ends: i64[>..] = [];
    var from = 0;
    loop {
        let e = arg_end(args, from);
        starts.push(from);
        ends.push(e);
        if e >= args.len { break; }
        from = e + 1;
    }
    let n = starts.len;
    if n < 2 || n > 3 { err(path, ln, usage); return; }
    let a_path = trim(args[starts[0]..ends[0]]);
    let a_alt = trim(args[starts[1]..ends[1]]);
    if a_alt.len == 0 { err(path, ln, usage); return; }
    let want, ok = plain_literal(a_path);
    if !ok { err(path, ln, usage); return; }
    var attrs: u8[>..] = [];
    if n == 3 && !decode_literal(trim(args[starts[2]..ends[2]]), attrs) { err(path, ln, usage); return; }
    let i = static_index(path, ln, want);
    if i < 0 { return; }
    var data: u8[>..] = [];
    if !read(statics[i].file, data) { return; }
    let w, h, known = image_size(data);
    var tag: u8[>..] = [];
    format(tag, "<img src=\"", statics[i].hashed, "\"");
    if known { format(tag, " width=\"", w, "\" height=\"", h, "\""); }
    tag.append(" alt=\"");
    out.append("out.append(\""); lit(out, tag); out.append("\"); gweb::put(out, "); out.append(a_alt); out.append("); ");
    tag.clear();
    tag.push('"');
    if !sets_attr(attrs, "loading") { tag.append(" loading=\"lazy\""); }
    if !sets_attr(attrs, "decoding") { tag.append(" decoding=\"async\""); }
    let retina = retina_url(statics[i].url);
    for r in statics {
        if retina.len > 0 && r.url == retina { format(tag, " srcset=\"", statics[i].hashed, " 1x, ", r.hashed, " 2x\""); }
    }
    if attrs.len > 0 { tag.push(' '); tag.append(attrs); }
    tag.push('>');
    out.append("out.append(\""); lit(out, tag); out.append("\"); ");
}

fn template_call(path: const u8[:], ln: i64, name: const u8[:], args: const u8[:], kind: i64, in_frag: bool, out: u8[>..]&,
                 segs: u8[>..]&, name_col: i64, args_col: i64) {
    if name == "slot" {
        if kind != K_LAYOUT { err(path, ln, "@slot() is for layout.html only"); }
        if args.len > 0 { err(path, ln, "@slot() takes no arguments"); }
        if kind == K_LAYOUT && (tpl_script || tpl_boost || tpl_trans || tpl_sse) { script_tag(out); }
        out.append("F(); ");
    } else if name == "asset" {
        asset_call(path, ln, args, out);
    } else if name == "image" {
        image_call(path, ln, args, out);
    } else if name == "meta" {
        if kind != K_LAYOUT { err(path, ln, "@meta() is for layout.html only"); }
        if args.len > 0 { err(path, ln, "@meta() takes no arguments"); }
        out.append("gweb::render_meta(out, req, ctx); ");
    } else if name[0] >= 'A' && name[0] <= 'Z' && find(name, "::") < 0 {
        if in_frag {
            var m: u8[>..] = [];
            format(m, "@", name, "() cannot be inside {#fragment} (fragments v1)");
            err(path, ln, m);
        }
        if !has_component(name) {
            var m: u8[>..] = [];
            format(m, "no component named ", name, " (there is no components/", name, ".gshtml); for a literal @ write &#64;");
            err(path, ln, m);
        } else if is_reactive_component(name) {
            reactive_call(path, ln, name, args, out);
        } else {
            seg_add(segs, out_col(out), name_col, name.len);
            out.append(name);
            out.append("::component(out, ");
            put_expr(out, segs, args, args_col);
            out.append("); ");
        }
    } else if args.len == 0 {
        seg_add(segs, out_col(out), name_col, name.len);
        out.append(name);
        out.append("(out); ");
    } else {
        seg_add(segs, out_col(out), name_col, name.len);
        out.append(name);
        out.append("(out, ");
        put_expr(out, segs, args, args_col);
        out.append("); ");
    }
}

// Every HTML line becomes one Goose line, so errors keep their line numbers.
fn compile_template(path: const u8[:], src: const u8[:], header: const u8[:], kind: i64, wrap: bool,
                    frags: u8[>..]&, out: u8[>..]&, recs: u8[>..]&) -> bool {
    let before = errors;
    tpl_script = find(src, "gw-target=\"") >= 0;
    tpl_boost = has_boost(src);
    if tpl_boost { uses_boost = true; }
    tpl_trans = find(src, "gw-enter") >= 0 || find(src, "gw-leave") >= 0;
    if tpl_trans { uses_trans = true; }
    tpl_sse = find(src, "gw-sse") >= 0;
    if tpl_sse { uses_sse = true; }
    out.append(header);
    if wrap { out.append("if gw_part == 0 { "); }
    if (tpl_script || tpl_boost || tpl_trans || tpl_sse) && kind != K_LAYOUT { script_tag(out); }
    var stack: u8[>..] = [];      // 'i' for if, 'f' for for, 'g' for fragment
    var stack_lines: i64[>..] = [];
    var raw = tscan::MARKUP;
    var slots = 0;
    var raw_line = 0;
    let lines = split(src, '\n');
    for line, li in lines {
        let ln = li + 1;
        let last = li == lines.len - 1;
        var text: u8[>..] = [];
        var segs: u8[>..] = [];
        var tcol = 0;   // where text starts in line
        var pos = 0;
        while pos < line.len {
            if tscan::is_raw(raw) {
                let e = tscan::raw_end(line, pos, raw);
                if text.len == 0 { tcol = pos; }
                text.append(line[pos..e]);
                pos = e;
                continue;
            }
            let at = tscan::next(line, pos, raw, false);
            if text.len == 0 { tcol = pos; }
            text.append(line[pos..at]);
            pos = at;
            if at == line.len || tscan::is_raw(raw) { continue; }
            if text.len > 0 {
                seg_add(segs, out_col(out), tcol, 0);
                out.append("out.append(\""); lit(out, text); out.append("\"); "); text.clear();
            }
            let rest = line[at..];
            if line[at] == '}' { err(path, ln, "'}' without '{'; for a literal brace write &#125;"); return false; }
            if line[at] == '@' {
                let open = tscan::call_open(line, at);
                let close = tscan::paren_end(line, open);
                if close < 0 { err(path, ln, "@name( needs its ) on the same line; for a literal @ write &#64;"); return false; }
                let name = line[at + 1..open];
                if name == "slot" { slots += 1; }
                var in_frag = false;
                for c in stack { if c == 'g' { in_frag = true; } }
                let args = line[open + 1..close];
                template_call(path, ln, name, trim(args), kind, in_frag, out, segs, at + 1, open + 1 + lead_ws(args));
                pos = close + 1;
                continue;
            }
            if starts_with(rest, "{{") { err(path, ln, tscan::old_syntax(rest)); return false; }
            if starts_with(rest, "{--") {
                let e = find(rest, "--}");
                if e < 0 { err(path, ln, "{-- needs --} on the same line"); return false; }
                pos = at + e + 3;
                continue;
            }
            let e = tscan::brace_end(line, at);
            if e < 0 { err(path, ln, "{ needs } on the same line; for a literal brace write &#123;"); return false; }
            template_tag(path, ln, trim(line[at + 1..e]), line, at, e, kind, stack, stack_lines, frags, out, segs);
            pos = e + 1;
        }
        if raw == tscan::MARKUP { raw_line = 0; } else if raw_line == 0 { raw_line = ln; }
        if !last {
            if text.len == 0 { tcol = line.len; }
            text.push('\n');
        }
        if text.len > 0 {
            seg_add(segs, out_col(out), tcol, 0);
            out.append("out.append(\""); lit(out, text); out.append("\"); ");
        }
        if segs.len > 0 { format(recs, "L ", ln, " ", ln, segs, "\n"); }
        if last { out.append(if wrap { "} }" } else { "}" }); }
        out.push('\n');
    }
    if stack.len > 0 {
        let top = stack[stack.len - 1];
        let what = if top == 'i' { "{#if} is never closed with {/if}" }
                   else if top == 'f' { "{#for} is never closed with {/for}" }
                   else { "{#fragment} is never closed with {/fragment}" };
        err(path, stack_lines[stack_lines.len - 1], what);
    }
    if tscan::unclosed(raw).len > 0 { err(path, raw_line, tscan::unclosed(raw)); }
    if kind == K_LAYOUT && slots == 0 { err(path, 0, "a layout needs @slot() where the page goes"); }
    return errors == before;
}

// unknown-attribute (Addendum 12, 8.2): the open tags of a page, layout or error page against the HTML lists.
fn warn_attributes(path: const u8[:], src: const u8[:]) {
    var w: u8[>..] = [];
    html::check(src, 0, 1, false, w);
    for l in split(w, '\n') {
        let f = split(l, '\t');
        if f.len != 2 { continue; }
        let ln, ok = parse_int(f[0]);
        if ok { warn(path, ln, "unknown-attribute", f[1]); }
    }
}

fn gen_template(src_path: const u8[:], ns: const u8[:], file_base: const u8[:], signature: const u8[:],
                imports: const u8[:], kind: i64, own: i64, frags: u8[>..]&) {
    var src: u8[>..] = [];
    if !read(src_path, src) { return; }
    scan_targets(src_path, src, own);
    warn_attributes(src_path, src);
    // The pre-scan is a guess; a wrong guess is compiled again.
    var wrap = kind == K_PAGE && find(src, "{#fragment ") >= 0;
    var out: u8[>..] = [];
    var recs: u8[>..] = [];
    var tries = 0;
    while tries < 2 {
        tries += 1;
        frags.clear();
        out.clear();
        recs.clear();
        var sig: u8[>..] = [];
        if wrap { format(sig, signature[..signature.len - 1], ", gw_part: i64)"); } else { sig.append(signature); }
        var header: u8[>..] = [];
        format(header, "namespace ", ns, "; ", imports, sig, " { ");
        if !compile_template(src_path, src, header, kind, wrap, frags, out, recs) { return; }
        if wrap == (frags.len > 0) { break; }
        wrap = frags.len > 0;
    }
    var dst: u8[>..] = [];
    format(dst, gen_root, "/", file_base, ".goose");
    write(dst, out);
    format(map_text, file_base, ".goose\t", src_path, "\n");
    format(srcmap_text, "file ", file_base, ".goose ", src_path, "\n");
    srcmap_text.append(recs);
}

// ---------------------------------------------------------------- gw-target

fn lower_eq(a: const u8[:], b: const u8[:]) -> bool {
    if a.len != b.len { return false; }
    for c, i in a {
        var x = c;
        var y = b[i];
        if x >= 'A' && x <= 'Z' { x += 32; }
        if y >= 'A' && y <= 'Z' { y += 32; }
        if x != y { return false; }
    }
    return true;
}

fn ws(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\r'; }

fn walk_tag(line: const u8[:], lt: i64, want: const u8[:], val: u8[>..]&, found: bool&) -> i64 {
    let n = line.len;
    var i = lt + 1;
    while i < n && !ws(line[i]) && line[i] != '>' && line[i] != '/' { i += 1; }
    while i < n {
        let c = line[i];
        if c == '>' { return i; }
        if ws(c) || c == '/' { i += 1; continue; }
        if c == '{' {
            let e = tscan::brace_end(line, i);
            if e < 0 { return -1; }
            i = e + 1;
            continue;
        }
        let ns = i;
        while i < n && !ws(line[i]) && line[i] != '>' && line[i] != '=' && line[i] != '/' && line[i] != '{' { i += 1; }
        let an = line[ns..i];
        var vs = i;
        var ve = i;
        if i < n && line[i] == '=' {
            i += 1;
            if i < n && (line[i] == '"' || line[i] == '\'') {
                let q = line[i];
                i += 1;
                vs = i;
                while i < n && line[i] != q {
                    if line[i] == '{' {
                        let e = tscan::brace_end(line, i);
                        if e < 0 { return -1; }
                        i = e + 1;
                    } else { i += 1; }
                }
                if i >= n { return -1; }
                ve = i;
                i += 1;
            } else {
                vs = i;
                while i < n && !ws(line[i]) && line[i] != '>' {
                    if line[i] == '{' {
                        let e = tscan::brace_end(line, i);
                        if e < 0 { return -1; }
                        i = e + 1;
                    } else { i += 1; }
                }
                ve = i;
            }
        }
        if want.len > 0 && !found && lower_eq(an, want) { val.append(line[vs..ve]); found = true; }
    }
    return -1;
}

fn scan_targets(path: const u8[:], src: const u8[:], own: i64) {
    for line, li in split(src, '\n') {
        let ln = li + 1;
        var from = 0;
        while from < line.len {
            let k = find(line[from..], "gw-target=\"");
            if k < 0 { break; }
            let at = from + k;
            from = at + 11;
            var lt = at;
            while lt > 0 && line[lt] != '<' { lt -= 1; }
            var tag_ok = line[lt] == '<';
            var end = -1;
            var unused: u8[>..] = [];
            var seen = false;
            if tag_ok { end = walk_tag(line, lt, "", unused, seen); }
            if end < at { tag_ok = false; }
            var tname = lt + 1;
            if tag_ok { while tname < line.len && !ws(line[tname]) && line[tname] != '>' && line[tname] != '/' { tname += 1; } }
            let el = if tag_ok { line[lt + 1..tname] } else { "" };
            let is_a = lower_eq(el, "a");
            let is_form = lower_eq(el, "form");
            if !is_a && !is_form {
                err(path, ln, "gw-target goes on <a href=\"...\"> or <form>, with the whole opening tag on one line");
                continue;
            }
            let close = find(line[at + 11..], "\"");
            let name = if close < 0 { "" } else { line[at + 11..at + 11 + close] };
            if !frag_name_ok(name) {
                var m: u8[>..] = [];
                format(m, "gw-target=\"", name, "\" takes a fragment name");
                err(path, ln, m);
                continue;
            }
            var url: u8[>..] = [];
            var has_url = false;
            walk_tag(line, lt, if is_a { "href" } else { "action" }, url, has_url);
            var method: u8[>..] = [];
            var has_method = false;
            if is_form { walk_tag(line, lt, "method", method, has_method); }
            var post = false;
            if is_form && has_method {
                if lower_eq(trim(method), "post") { post = true; }
                else if !lower_eq(trim(method), "get") {
                    err(path, ln, "gw-target: a form's method is get or post");
                    continue;
                }
            }
            let u = trim(url);
            if u.len > 0 && u[0] != '/' && u[0] != '?' {
                err(path, ln, "a gw-target URL starts with / (or is empty or starts with ? for the page itself)");
                continue;
            }
            var t = Target { path: "", line: ln, url: "", name: "", post: post, own: own };
            if path.len >= 512 || u.len >= 512 { err(path, ln, "gw-target: the path or URL is too long"); continue; }
            t.path.append(path);
            t.url.append(u);
            t.name.append(name);
            targets.push(t);
            uses_fragments = true;
        }
    }
}

fn fits_count(d: const Dir&, count: i64) -> bool {
    let kind = catch_kind(d.rel);
    if kind == 0 { return seg_count(d.rel) == count; }
    if kind == 2 { return count > prefix_len(d.rel); }
    return count >= prefix_len(d.rel);
}

// The candidates for a path of count segments (17 means 17 or more), in the order the dispatcher tries them.
fn dispatch_order(count: i64, order: i64[>..]&) {
    for d, i in dirs {
        if (d.route || d.page_html) && fits_count(d, count) {
            var at = order.len;
            let mine: u8[..512] = d.rel;
            for k in order.len {
                let other: u8[..512] = dirs[order[k]].rel;
                if route_before(mine, other) { at = k; break; }
            }
            order.push(i);
            var j = order.len - 1;
            while j > at { order[j] = order[j - 1]; j -= 1; }
            order[at] = i;
        }
    }
}

// A segment with a { is a wildcard that fits a [name] folder only.
fn match_url(url: const u8[:]) -> i64 {
    var cut = url.len;
    for c, i in url { if c == '?' || c == '#' { cut = i; break; } }
    let p = url[1..cut];
    var starts: i64[>..] = [];
    var ends: i64[>..] = [];
    if p.len > 0 {
        var s = 0;
        var i = 0;
        while i < p.len {
            if p[i] == '{' {
                let e = tscan::brace_end(p, i);
                if e < 0 { return -1; }
                i = e + 1;
            } else if p[i] == '/' { starts.push(s); ends.push(i); s = i + 1; i += 1; }
            else { i += 1; }
        }
        starts.push(s);
        ends.push(p.len);
    }
    var order: i64[>..] = [];
    dispatch_order(min(starts.len, 17), order);
    for di in order {
        let dd = dirs[di];
        let segs = split(dd.rel, '/');
        var fits = true;
        let compared = if catch_kind(dd.rel) > 0 { prefix_len(dd.rel) } else { starts.len };
        for k in compared {
            let seg = p[starts[k]..ends[k]];
            let dyn = segs[k].len > 0 && segs[k][0] == '[';
            if find(seg, "{") >= 0 { if !dyn { fits = false; } }
            else if !dyn && segs[k] != seg { fits = false; }
        }
        if fits { return di; }
    }
    return -1;
}

// Run after every page's fragments and POST flag are known.
fn check_targets() {
    for t in targets {
        let url: u8[..512] = t.url;
        var di = -1;
        if url.len == 0 || url[0] == '?' {
            if t.own < 0 { err(t.path, t.line, "gw-target here needs a path starting with /"); continue; }
            di = t.own;
        } else {
            di = match_url(url);
            if di < 0 {
                var m: u8[>..] = [];
                format(m, "gw-target: no page matches ", url);
                err(t.path, t.line, m);
                continue;
            }
        }
        let d = dirs[di];
        if d.route {
            var m: u8[>..] = [];
            format(m, "gw-target: ", url, " is a route.goose; fragments come from pages");
            err(t.path, t.line, m);
            continue;
        }
        var page: u8[>..] = [];
        app_path(page, d, "page.html");
        if !has_name(d.frags, t.name) {
            var m: u8[>..] = [];
            format(m, "gw-target: ", page, " has no {#fragment ", t.name, "}");
            err(t.path, t.line, m);
        }
        if t.post && !d.has_post {
            var goose: u8[>..] = [];
            app_path(goose, d, "page.goose");
            var m: u8[>..] = [];
            format(m, "gw-target: method=\"post\" needs fn POST( in ", goose);
            err(t.path, t.line, m);
        }
    }
}

// A string-literal url of http::get or http::post must reach a route.goose that answers that method, found the
// way a gw-target url finds its page. Urls that are not literals are not checked.
fn check_http() {
    for t in http_calls {
        let url: u8[..512] = t.url;
        let meth = if t.post { "POST" } else { "GET" };
        var m: u8[>..] = [];
        if url.len == 0 || url[0] != '/' {
            format(m, "http::", if t.post { "post" } else { "get" }, ": a literal url starts with / (the same site): ", url);
            err(t.path, t.line, m);
            continue;
        }
        let di = match_url(url);
        let bit = if t.post { 2 } else { 0 };
        if di < 0 || !dirs[di].route || ((dirs[di].methods >> bit) & 1) == 0 {
            format(m, "http::", if t.post { "post" } else { "get" }, ": no route ", meth, " ", url);
            err(t.path, t.line, m);
        }
    }
}

// ---------------------------------------------------------------- main.goose

let SIG = "(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&)";

fn allow_list(d: const Dir&, out: u8[>..]&) {
    var first = true;
    for i in 7 {
        let has = (d.methods >> i) & 1 == 1 || (i == 1 && d.methods & 1 == 1) || i == 6;
        if !has { continue; }
        if !first { out.append(", "); }
        out.append(METHODS[i]);
        first = false;
    }
}

fn middleware_before(m: u8[>..]&, d: const Dir&, rq: const u8[:]) {
    for o in dirs {
        if o.middleware && o.has_before && is_ancestor(o.rel, d.rel) {
            format(m, "    if !", o.mw_ns, "::before(", rq, ", ctx, res) { return; }\n");
        }
    }
}

fn middleware_after(m: u8[>..]&, d: const Dir&, rq: const u8[:]) {
    var k = dirs.len;
    while k > 0 {
        k -= 1;
        let o = dirs[k];
        if o.middleware && o.has_after && is_ancestor(o.rel, d.rel) {
            format(m, "    ", o.mw_ns, "::after(", rq, ", ctx, res);\n");
        }
    }
}

// DESIGN-ADDENDUM-14 D9: the MAX_UPLOAD check, then multipart turned into a plain form in r.
fn gen_upload_prelude(m: u8[>..]&, ns: const u8[:], max_upload: bool) {
    if max_upload {
        // The dispatcher calls finish after this function returns, and finish answers the Error outcome.
        format(m, "    if ", ns, "::MAX_UPLOAD > 0 && gweb::content_length(req) > ", ns, "::MAX_UPLOAD { gweb::fail(ctx, 413, \"The upload is too large.\"); return; }\n");
    }
    m.append("    var mp: u8[>..] = [];\n    var r = req;\n");
    m.append("    if gweb::is_multipart(req) { if !gweb::multipart_begin(req, ctx, res, mp) { return; } r.body = mp; }\n");
}

fn gen_route_fn(m: u8[>..]&, d: const Dir&, i: i64) {
    var allow: u8[>..] = [];
    allow_list(d, allow);
    // A route with POST, PUT or PATCH reads the body through r. The prelude comes first because the CSRF check reads the body.
    let body = d.methods & 0x1c != 0;
    let rq = if body { "r" } else { "req" };
    format(m, "fn route_", i, SIG, " {   // app/", d.rel, if d.rel.len > 0 { "/" } else { "" }, "route.goose\n");
    if body { gen_upload_prelude(m, d.route_ns, d.max_upload); }
    if d.csrf_const { format(m, "    if ", d.route_ns, "::CSRF && !gweb::csrf_ok(", rq, ", res) { return; }\n"); }
    else if d.methods & 0x3c != 0 { format(m, "    if !gweb::csrf_ok(", rq, ", res) { return; }\n"); }
    middleware_before(m, d, rq);
    m.append("    match req.method {\n");
    for k in 7 {
        let has = (d.methods >> k) & 1 == 1;
        if has { format(m, "        ", VARIANTS[k], " => ", d.route_ns, "::", METHODS[k], "(", rq, ", ctx, res),\n"); }
        else if k == 1 && d.methods & 1 == 1 { format(m, "        Head => ", d.route_ns, "::GET(", rq, ", ctx, res),\n"); }
        else if k == 6 { format(m, "        Options => gweb::options(res, \"", allow, "\"),\n"); }
    }
    format(m, "        _ => gweb::method_not_allowed(res, \"", allow, "\"),\n");
    m.append("    }\n");
    middleware_after(m, d, rq);
    m.append("}\n");
}

// The namespace of the loading.html a page in rel uses: the nearest at or above its folder; "" for none.
fn nearest_loading(out: u8[>..]&, rel: const u8[:]) {
    var best = -1;
    var best_len = -1;
    for o, k in dirs {
        if o.loading && is_ancestor(o.rel, rel) && o.rel.len > best_len { best = k; best_len = o.rel.len; }
    }
    if best >= 0 { out.append(dirs[best].loading_ns); }
}

fn gen_render_stmt(m: u8[>..]&, d: const Dir&, props: bool, part: const u8[:], rq: const u8[:]) {
    var closes = 0;
    for o in dirs {
        if o.layout && is_ancestor(o.rel, d.rel) { format(m, o.layout_ns, "::render(res.body, ", rq, ", ctx) { "); closes += 1; }
    }
    format(m, d.page_ns, "::render(res.body, ", rq, ", ctx", if props { ", props" } else { "" }, if part.len > 0 { ", " } else { "" }, part, ");");
    // A whole page carries the nearest loading.html as a template for gwi.js (DESIGN-ADDENDUM-14, section 4).
    var ld: u8[>..] = [];
    nearest_loading(ld, d.rel);
    if ld.len > 0 {
        format(m, " res.body.append(\"<template id=\\\"gw-loading\\\">\"); ", ld, "::render(res.body, ", rq, ", ctx); res.body.append(\"</template>\");");
    }
    for c in closes { m.append(" };"); }
}

fn gen_page_reply(m: u8[>..]&, d: const Dir&, props: bool, indent: const u8[:], rq: const u8[:]) {
    format(m, indent, "if ctx.outcome == gweb::Outcome.Continue {\n", indent, "    ");
    if d.frags.len == 0 { gen_render_stmt(m, d, props, "", rq); }
    else {
        format(m, "if part > 0 { gweb::fragment_reply(", rq, ", ctx, res); ");
        format(m, d.page_ns, "::render(res.body, ", rq, ", ctx", if props { ", props" } else { "" }, ", part); }\n");
        format(m, indent, "    else { ");
        gen_render_stmt(m, d, props, "0", rq);
        m.append(" }");
    }
    format(m, "\n", indent, "    if ctx.status != 0 { res.status = http::status_from_code(ctx.status); }\n", indent, "}\n");
}

// True when the page, or a layout around it, writes gweb::csrf_ fields.
fn starts_token(d: const Dir&) -> bool {
    if d.page_csrf { return true; }
    for o in dirs { if o.layout && o.layout_csrf && is_ancestor(o.rel, d.rel) { return true; } }
    return false;
}

fn gen_page_fn(m: u8[>..]&, d: const Dir&, i: i64) {
    let allow = if d.has_post { "GET, HEAD, POST, OPTIONS" } else { "GET, HEAD, OPTIONS" };
    let rq = if d.has_post { "r" } else { "req" };   // r: the request with its multipart body made plain (D9)
    format(m, "fn page_", i, SIG, " {   // app/", d.rel, if d.rel.len > 0 { "/" } else { "" }, "page.html\n");
    m.append("    match req.method {\n");
    format(m, "        Get, Head", if d.has_post { ", Post" } else { "" }, " => {},\n");
    format(m, "        Options => { gweb::options(res, \"", allow, "\"); return; },\n");
    format(m, "        _ => { gweb::method_not_allowed(res, \"", allow, "\"); return; },\n");
    m.append("    }\n");
    if d.has_post {
        gen_upload_prelude(m, d.page_ns, d.max_upload);
        m.append("    if !gweb::csrf_ok(r, res) { return; }\n");
    }
    middleware_before(m, d, rq);
    if d.revalidate > 0 {
        m.append("    if gweb::cache_serve(req, ctx, res) {\n");
        middleware_after(m, d, rq);
        m.append("        return;\n    }\n");
    }
    m.append("    gweb::html(res, http::Status.Ok);\n");
    if starts_token(d) { format(m, "    if !gweb::csrf_begin(", rq, ", ctx, res) { return; }\n"); }
    if d.frags.len > 0 {
        format(m, "    let part = gweb::fragment_index(", rq, ", [");
        for n, k in split(d.frags, ' ') { if k > 0 { m.append(", "); } format(m, "\"", n, "\""); }
        m.append("]);\n");
    }
    if d.has_post {
        m.append("    if req.method == http::Method.Post {\n");
        format(m, "        let props = ", d.page_ns, "::POST(r, ctx", if d.has_post_res { ", res" } else { "" }, ");\n");
        gen_page_reply(m, d, true, "        ", rq);
        m.append("    } else {\n");
        format(m, "        let props = ", d.page_ns, "::load(r, ctx", if d.has_load_res { ", res" } else { "" }, ");\n");
        gen_page_reply(m, d, true, "        ", rq);
        m.append("    }\n");
    } else {
        if d.has_load { format(m, "    let props = ", d.page_ns, "::load(req, ctx", if d.has_load_res { ", res" } else { "" }, ");\n"); }
        gen_page_reply(m, d, d.has_load, "    ", rq);
    }
    if d.revalidate > 0 { format(m, "    gweb::cache_store(req, ctx, res, ", d.revalidate, ");\n"); }
    middleware_after(m, d, rq);
    m.append("}\n");
}

// Ranks each segment literal, [name], catch-all; the first segment whose ranks differ decides.
fn route_before(a: const u8[:], b: const u8[:]) -> bool {
    let sa = split(a, '/');
    let sb = split(b, '/');
    for k in min(sa.len, sb.len) {
        let ra = seg_rank(sa[k]);
        let rb = seg_rank(sb[k]);
        if ra != rb { return ra < rb; }
    }
    return false;
}

fn seg_rank(s: const u8[:]) -> i64 {
    let kind = seg_kind(s);
    if kind == 3 { return 2; }
    return kind;
}

// 0 literal, 1 [name], 2 [...name], 3 [[...name]], -1 a malformed dynamic folder name.
fn seg_kind(s: const u8[:]) -> i64 {
    if s.len == 0 || s[0] != '[' { return 0; }
    if starts_with(s, "[[...") {
        if s.len >= 7 && s[s.len - 1] == ']' && s[s.len - 2] == ']' && is_ident(s[5..s.len - 2]) { return 3; }
        return -1;
    }
    if starts_with(s, "[...") {
        if s.len >= 5 && s[s.len - 1] == ']' && is_ident(s[4..s.len - 1]) { return 2; }
        return -1;
    }
    if s.len >= 3 && s[s.len - 1] == ']' && is_ident(s[1..s.len - 1]) { return 1; }
    return -1;
}

fn last_seg(rel: const u8[:]) -> const u8[:] {
    for k in rel.len {
        let i = rel.len - 1 - k;
        if rel[i] == '/' { return rel[i + 1..]; }
    }
    return rel;
}

fn parent_of(rel: const u8[:]) -> const u8[:] {
    let n = rel.len - last_seg(rel).len;
    if n == 0 { return ""; }
    return rel[..n - 1];
}

// The kind of the last segment when it is a catch-all (2 or 3), else 0.
fn catch_kind(rel: const u8[:]) -> i64 {
    let k = seg_kind(last_seg(rel));
    if k >= 2 { return k; }
    return 0;
}

fn prefix_len(rel: const u8[:]) -> i64 { return seg_count(rel) - 1; }

// The name inside [...name] or [[...name]].
fn catch_name(seg: const u8[:]) -> const u8[:] {
    if seg_kind(seg) == 3 { return seg[5..seg.len - 2]; }
    return seg[4..seg.len - 1];
}

fn seg_count(rel: const u8[:]) -> i64 {
    if rel.len == 0 { return 0; }
    var n = 1;
    for c in rel { if c == '/' { n += 1; } }
    return n;
}

// Writes .gooseweb/t.goose from locales/; errors stop the build.
fn gen_locales() {
    has_locales = true;
    var names: u8[>..] = [];
    if !list_dir("locales", names) { err("locales", 0, "cannot read"); return; }
    var def: u8[>..] = [];
    let has_def = read_file("locales/default", def);
    i18n::start(def, has_def);
    for f in split(names, '\n') {
        if f.len == 0 || f[0] == '.' || !ends_with(f, ".txt") { continue; }
        var p: u8[>..] = [];
        format(p, "locales/", f);
        var src: u8[>..] = [];
        if !read(p, src) { continue; }
        i18n::add_file(f, src);
    }
    var g: u8[>..] = [];
    var e: u8[>..] = [];
    if !i18n::compile(g, e, locale_notes) {
        write_stderr(e);
        note_errors(e);
        for c in e { if c == '\n' { errors += 1; } }
        if e.len == 0 { errors += 1; }
        return;
    }
    locale_count = i18n::count();
    var dst: u8[>..] = [];
    format(dst, gen_root, "/t.goose");
    write(dst, g);
}

// A route's or page's place in ROUTES, the label the metrics and the access log use.
fn route_index(di: i64) -> i64 {
    var n = 0;
    for d, j in dirs {
        if j >= di { break; }
        if d.route || d.page_html { n += 1; }
    }
    return n;
}

fn gen_dispatch(m: u8[>..]&) {
    format(m, "fn dispatch", SIG, " -> i64 {\n");
    if statics.len > 0 {
        m.append("    if req.method == http::Method.Get || req.method == http::Method.Head {\n");
        m.append("        let i, hit = static_file(req, res);\n");
        m.append("        if hit { return i; }\n");
        m.append("    }\n");
    }
    if has_locales {
        m.append("    ctx.locale = gweb::pick_locale(req, t::TAGS);\n");
        if locale_count >= 2 { m.append("    http::set_header(res, \"Vary\", \"Accept-Language, Cookie\");\n"); }
    }
    if has_sitemap {
        m.append("    if req.path == \"/sitemap.xml\" { sitemap_xml(req, ctx, res); finish(req, ctx, res); return -1; }\n");
        if !has_static("/robots.txt") { m.append("    if req.path == \"/robots.txt\" { robots_txt(req, ctx, res); finish(req, ctx, res); return -1; }\n"); }
    }
    m.append("    var seg: const u8[:][16] = [\"\"; 16];\n");
    m.append("    var starts: i64[16] = [0; 16];\n");
    m.append("    var ends: i64[16] = [0; 16];\n");
    m.append("    let n = gweb::split(req.path, seg, starts, ends);\n");
    m.append("    match n {\n");
    for count in 18 {
        var order: i64[>..] = [];
        dispatch_order(count, order);
        if order.len == 0 { continue; }
        format(m, "        ", count, " => {\n");
        for i in order {
            let d = dirs[i];
            let kind = catch_kind(d.rel);
            let k = prefix_len(d.rel);
            var cond: u8[>..] = [];
            var params: u8[>..] = [];
            if count > 0 || kind > 0 {
                for s, j in split(d.rel, '/') {
                    if kind > 0 && j >= k { break; }
                    if s[0] == '[' {
                        if params.len > 0 { params.append(" && "); }
                        format(params, "gweb::set_param(ctx, \"", s[1..s.len - 1], "\", seg[", j, "])");
                    } else {
                        if cond.len > 0 { cond.append(" && "); }
                        cond.append("seg["); format(cond, j); cond.append("] == \""); lit(cond, s); cond.push('"');
                    }
                }
            }
            if kind > 0 {
                if params.len > 0 { params.append(" && "); }
                let name = catch_name(last_seg(d.rel));
                // A path ending in / leaves an empty last segment, which no catch-all accepts.
                if count > k { format(params, "starts[", k, "] < req.path.len && gweb::set_rest(ctx, \"", name, "\", req.path[starts[", k, "]..])"); }
                else { format(params, "gweb::set_rest(ctx, \"", name, "\", \"\")"); }
            }
            let call_kind = if d.route { "route_" } else { "page_" };
            var call: u8[>..] = [];
            format(call, "ctx.route = ", i, "; ctx.route_label = ", route_index(i), "; gweb::inflight_route(ctx.worker, ", i, "); ", call_kind, i, "(req, ctx, res);");
            var body: u8[>..] = [];
            if params.len > 0 { format(body, "if ", params, " { ", call, " } else { gweb::not_found(ctx); } finish(req, ctx, res); return -1;"); }
            else { format(body, call, " finish(req, ctx, res); return -1;"); }
            var u: u8[>..] = [];
            url_of(u, d.rel);
            if cond.len > 0 { format(m, "            if ", cond, " { ", body, " }   // ", u, "\n"); }
            else { format(m, "            { ", body, " }   // ", u, "\n"); break; }
        }
        m.append("        },\n");
    }
    m.append("        _ => {},\n");
    m.append("    }\n");
    m.append("    gweb::not_found(ctx);\n");
    m.append("    finish(req, ctx, res);\n");
    m.append("    return -1;\n");
    m.append("}\n");
}

fn gen_static(m: u8[>..]&) {
    for s, i in statics {
        let src = if s.embed.len > 0 { s.embed } else { s.file };
        if src.len > 0 && src[0] == '/' {
            // A package's file lies outside the project: copy it beside main.goose and embed the copy.
            var data: u8[>..] = [];
            var dst: u8[>..] = [];
            format(dst, gen_root, "/pkg_static_", i);
            if read(src, data) { write(dst, data); }
            format(m, "let S", i, " = embed_file(\"pkg_static_", i, "\");\n");
        } else {
            format(m, "let S", i, " = embed_file(\"../"); lit(m, src); m.append("\");\n");
        }
        if s.gz >= 0 { format(m, "let S", s.gz, " = embed_file(\"../"); lit(m, gen_root); format(m, "/_gz/", i, ".gz\");\n"); }
    }
    m.append("fn static_bytes(i: i64) -> const u8[:] {\n");
    for s, i in statics {
        format(m, "    if i == ", i, " { return S", i, "; }\n");
        if s.gz >= 0 { format(m, "    if i == ", s.gz, " { return S", s.gz, "; }\n"); }
    }
    m.append("    return \"\";\n}\n");
    m.append("fn static_file(req: const http::Request&, res: http::Response&) -> i64, bool {\n");
    if statics.len > 0 {
        m.append("    let p = req.path;\n    match p.len {\n");
        var lens: i64[>..] = [];
        for s in statics {
            if !contains(lens, s.url.len) { lens.push(s.url.len); }
            if !contains(lens, s.hashed.len) { lens.push(s.hashed.len); }
        }
        sort(lens);
        for l in lens {
            format(m, "        ", l, " => {\n");
            for s, i in statics {
                for hashed in [false, true] {
                    var u: const u8[:] = s.url;
                    if hashed { u = s.hashed; }
                    if u.len != l { continue; }
                    m.append("            if p == \""); lit(m, u);
                    format(m, "\" { return gweb::send_static(req, res, ", i, ", ", s.gz, ", \"", s.ctype, "\", \""); lit(m, s.etag);
                    format(m, "\", ", if hashed { "true" } else { "false" }, "), true; }\n");
                }
            }
            m.append("        },\n");
        }
        m.append("        _ => {},\n    }\n");
    }
    m.append("    return -1, false;\n}\n");
}

// For URLs known only at run time; an unknown path comes back unchanged.
fn gen_asset_url(m: u8[>..]&) {
    m.append("fn gweb::asset_url(path: const u8[:]) -> const u8[:] {\n");
    if statics.len > 0 {
        m.append("    match path.len {\n");
        var lens: i64[>..] = [];
        for s in statics { if !contains(lens, s.url.len) { lens.push(s.url.len); } }
        sort(lens);
        for l in lens {
            format(m, "        ", l, " => {\n");
            for s in statics {
                if s.url.len != l { continue; }
                m.append("            if path == \""); lit(m, s.url);
                m.append("\" { return \""); lit(m, s.hashed); m.append("\"; }\n");
            }
            m.append("        },\n");
        }
        m.append("        _ => {},\n    }\n");
    }
    m.append("    return path;\n}\n");
}

// Both routes answer GET and HEAD only, like a route.goose with those two methods.
fn gen_sitemap(m: u8[>..]&) {
    if !has_sitemap { return; }
    for name in ["sitemap_xml", "robots_txt"] {
        if name == "robots_txt" && has_static("/robots.txt") { continue; }
        format(m, "fn ", name, SIG, " {\n");
        m.append("    match req.method {\n        Get, Head => {},\n");
        m.append("        Options => { gweb::options(res, \"GET, HEAD, OPTIONS\"); return; },\n");
        m.append("        _ => { gweb::method_not_allowed(res, \"GET, HEAD, OPTIONS\"); return; },\n    }\n");
        if name == "robots_txt" {
            if has_robots { m.append("    gweb::robots_begin(res);\n    smap::robots(req, ctx, res.body);\n}\n"); }
            else { m.append("    gweb::robots_reply(req, res);\n}\n"); }
            continue;
        }
        m.append("    var s = gweb::Sitemap { base: [], body: [], count: 0 };\n    gweb::sitemap_init(req, s);\n");
        for d in dirs {
            if !d.page_html || !d.in_sitemap || find(d.rel, "[") >= 0 { continue; }
            var u: u8[>..] = [];
            url_of(u, d.rel);
            m.append("    gweb::sitemap_add(s, \""); lit(m, u); m.append("\");\n");
        }
        if has_entries { m.append("    smap::entries(req, ctx, s);\n"); }
        m.append("    gweb::sitemap_reply(res, s);\n}\n");
    }
    m.append("\n");
}

fn gen_finish(m: u8[>..]&) {
    m.append("fn finish(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {\n");
    m.append("    match ctx.outcome {\n        Continue => {},\n        Done => {},\n        NotFound => {\n");
    if has_not_found {
        m.append("            ctx.title.clear();\n            res.body.clear();\n            gweb::html(res, http::Status.NotFound);\n");
        var root_layout: u8[>..] = [];
        for d in dirs { if d.rel.len == 0 && d.layout { root_layout.append(d.layout_ns); } }
        var root_csrf = not_found_csrf;
        for d in dirs { if d.rel.len == 0 && d.layout && d.layout_csrf { root_csrf = true; } }
        m.append("            ");
        if root_csrf { m.append("if gweb::csrf_begin(req, ctx, res) { "); }
        if root_layout.len > 0 { format(m, root_layout, "::render(res.body, req, ctx) { nf::render(res.body, req, ctx); };"); }
        else { m.append("nf::render(res.body, req, ctx);"); }
        m.append(if root_csrf { " }\n" } else { "\n" });
    } else {
        m.append("            res.body.clear();\n            gweb::plain_not_found(res);\n");
    }
    m.append("        },\n        Redirect => gweb::apply_redirect(ctx, res),\n");
    // Phase 1: a crash while this renders makes the supervisor start at attempt 2 (D12).
    m.append("        Error => { gweb::inflight_phase(ctx.worker, 1); error_reply(ctx.route, 1, req, ctx, res, \"\"); },\n    }\n}\n");
}

// The dir index of the error.html a page or route in rel uses (D10): the nearest at or above its folder; -1 for none.
fn nearest_error(rel: const u8[:]) -> i64 {
    var best = -1;
    var best_len = -1;
    for o, k in dirs {
        if o.error_html && is_ancestor(o.rel, rel) && o.rel.len > best_len { best = k; best_len = o.rel.len; }
    }
    return best;
}

// error_reply: attempt 1 renders the nearest error.html inside the layouts at or above the error file's folder;
// attempt 2 (after a crash in attempt 1) renders it bare. No error.html: the built-in page. A route.goose dir: JSON.
// why is the abort text of a crash, "" for a gweb::fail.
fn gen_error_reply(m: u8[>..]&) {
    let root = nearest_error("");
        m.append("fn error_at(route: i64) -> i64 {\n    match route {\n");
    for d, i in dirs {
        if !d.route && !d.page_html { continue; }
        let e = nearest_error(d.rel);
        if e >= 0 && e != root { format(m, "        ", i, " => { return ", e, "; },\n"); }
    }
    format(m, "        _ => {},\n    }\n    return ", root, ";\n}\n\n");
    m.append("fn error_reply(route: i64, attempt: i64, req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&, why: const u8[:]) {\n");
    m.append("    let crashed = !(ctx.outcome == gweb::Outcome.Error);\n");
    m.append("    var status: i64 = 500;\n    var message: u8[..512] = \"Internal Server Error\";\n");
    m.append("    if !crashed { status = ctx.error_status; message.clear(); message.append(ctx.error_message); }\n");
    m.append("    var info = gweb::new_error(status, message, crashed);\n");
    m.append("    if why.len > 0 { gweb::log_error(info, req, why); } else { gweb::log_error(info, req, message); }\n");
    m.append("    if gweb::dev_mode() { gweb::dev_detail(info, req, why); }\n");
    m.append("    res.headers.clear();\n");
    var api: u8[>..] = [];
    for d, i in dirs {
        if !d.route { continue; }
        if api.len > 0 { api.append(" || "); }
        format(api, "route == ", i);
    }
    if api.len > 0 { format(m, "    if ", api, " { gweb::error_json(res, info); return; }\n"); }
    m.append("    ctx.title.clear();\n    gweb::error_start(res, info);\n");
    m.append("    match error_at(route) {\n");
    for e, k in dirs {
        if !e.error_html { continue; }
        var csrf = e.error_csrf;
        var wrapped: u8[>..] = [];
        var closes = 0;
        for o in dirs {
            if o.layout && is_ancestor(o.rel, e.rel) {
                format(wrapped, o.layout_ns, "::render(res.body, req, ctx) { ");
                closes += 1;
                if o.layout_csrf { csrf = true; }
            }
        }
        format(wrapped, e.error_ns, "::render(res.body, req, ctx, info);");
        for c in closes { wrapped.append(" };"); }
        format(m, "        ", k, " => {\n            ");
        if csrf { m.append("if gweb::csrf_begin(req, ctx, res) { "); }
        if closes > 0 { format(m, "if attempt == 1 { ", wrapped, " } else { ", e.error_ns, "::render(res.body, req, ctx, info); }"); }
        else { format(m, e.error_ns, "::render(res.body, req, ctx, info);"); }
        m.append(if csrf { " }\n        },\n" } else { "\n        },\n" });
    }
    m.append("        _ => gweb::builtin_page(res.body, info),\n    }\n");
    m.append("    if gweb::dev_mode() { gweb::dev_error_script(res.body, info); }\n}\n");
}

// The generated main's export mode: each page is rendered in process through dispatch with a synthetic request.
let EXPORT_RUNTIME = """
struct Export { pages: i64, files: i64, failed: bool }

fn export_error(a: const u8[:], b: const u8[:], c: const u8[:], st: Export&) {
    var s: u8[>..] = [];
    format(s, "gweb: ", a, b, c, "\n");
    write_stderr(s);
    st.failed = true;
}

fn export_get(path: const u8[:], owner_fd: i32, st: Export&, out: u8[>..]&) -> bool {
    var raw: u8[>..] = [];
    format(raw, "GET ", path, " HTTP/1.1\r\nHost: localhost\r\n\r\n");
    let req, parsed = http::parse_request(raw);
    var ready = false;
    match parsed { Ready => { ready = true; }, _ => {}, }
    if !ready { export_error(path, ": not a valid request path", "", st); return false; }
    var ctx = gweb::new_ctx(0, owner_fd);
    var res = http::new_response();
    let hit = dispatch(req, ctx, res);
    if res.status != http::Status.Ok {
        var code: u8[>..] = [];
        format(code, http::code(res.status));
        export_error(path, ": the reply is ", code, st);
        return false;
    }
    if hit >= 0 { out.append(static_bytes(hit)); } else { out.append(res.body); }
    return true;
}

fn export_write(file: const u8[:], data: const u8[:], st: Export&) -> bool {
    for c, i in file { if c == '/' && i > 0 { make_dir(file[..i]); } }
    if write_file(file, data) { return true; }
    export_error("cannot write ", file, "", st);
    return false;
}

fn export_page(dir: const u8[:], path: const u8[:], owner_fd: i32, st: Export&) {
    var body: u8[>..] = [];
    if !export_get(path, owner_fd, st, body) { return; }
    var file: u8[>..] = [];
    format(file, dir, if path == "/" { "/index" } else { path }, ".html");
    if export_write(file, body, st) { st.pages += 1; }
}

fn export_generated(dir: const u8[:], path: const u8[:], owner_fd: i32, st: Export&) {
    var body: u8[>..] = [];
    if !export_get(path, owner_fd, st, body) { return; }
    var file: u8[>..] = [];
    format(file, dir, path);
    if export_write(file, body, st) { st.files += 1; }
}

fn export_static(dir: const u8[:], url: const u8[:], data: const u8[:], st: Export&) {
    var file: u8[>..] = [];
    format(file, dir, url);
    if export_write(file, data, st) { st.files += 1; }
}

""";

// Pages without a dynamic segment, then each static_paths() path, then the static files at both URLs, then the generated routes.
fn gen_export(m: u8[>..]&) {
    m.append(EXPORT_RUNTIME);
    m.append("fn run_export(out_dir: const u8[:], owner_fd: i32) -> bool {\n");
    m.append("    var dir: u8[>..] = [];\n    dir.append(out_dir);\n");
    m.append("    while dir.len > 1 && dir[dir.len - 1] == '/' { dir.pop(); }\n");
    m.append("    var st = Export { pages: 0, files: 0, failed: false };\n");
    for d in dirs {
        if !d.page_html { continue; }
        var u: u8[>..] = [];
        url_of(u, d.rel);
        if find(d.rel, "[") < 0 { m.append("    export_page(dir, \""); lit(m, u); m.append("\", owner_fd, st);\n"); }
        else if d.static_paths { format(m, "    for p in ", d.page_ns, "::static_paths() { export_page(dir, p, owner_fd, st); }\n"); }
        else { m.append("    print(\"gweb: skipped "); lit(m, u); m.append(": it has a dynamic segment and no fn static_paths() in its page.goose\");\n"); }
    }
    for s, i in statics {
        for hashed in [false, true] {
            m.append("    export_static(dir, \""); lit(m, if hashed { s.hashed } else { s.url });
            format(m, "\", static_bytes(", i, "), st);\n");
        }
    }
    if has_sitemap {
        m.append("    export_generated(dir, \"/sitemap.xml\", owner_fd, st);\n");
        if !has_static("/robots.txt") { m.append("    export_generated(dir, \"/robots.txt\", owner_fd, st);\n"); }
    }
    m.append("    print(\"gweb: exported \", st.pages, \" pages and \", st.files, \" files to \", dir);\n");
    m.append("    return !st.failed;\n}\n\n");
    if has_state { m.append("thread_fn export_thread(owner_fd: i32, cfg: gweb::Config) {\n    exit(if run_export(cfg.export_dir, owner_fd) { 0 } else { 1 });\n}\n\n"); }
}

// One thread reads every hub event and forwards it to the handlers app/socket.goose defines; without one, messages are dropped.
// The handlers get a fresh Ctx per event: id and topic say which connection, and gweb::send, publish and state::ask work as in a route.
fn gen_hub_thread(m: u8[>..]&) {
    m.append("thread_fn hub_thread(cfg: gweb::Config, owner_fd: i32) {\n");
    m.append("    let h = net::Hub { handle: cfg.hub };\n    var msg: u8[>..] = [];\n    var topic: u8[>..] = [];\n");
    m.append("    loop {\n        msg.clear();\n        topic.clear();\n        let id, ev = h.next(msg, topic);\n");
    m.append("        var ctx = gweb::new_ctx(cfg.workers, owner_fd, cfg.hub);\n        match ev {\n");
    if socket_open { m.append("            Open => { socket::open(ctx, id, topic); },\n"); }
    if socket_message {
        m.append("            Text => { socket::message(ctx, id, topic, msg, false); },\n");
        m.append("            Binary => { socket::message(ctx, id, topic, msg, true); },\n");
    }
    if socket_close { m.append("            Close => { socket::close(ctx, id, topic); },\n"); }
    m.append("            Failed => { print(\"gweb: the hub stopped\"); return; },\n            _ => {},\n        }\n    }\n}\n\n");
    m.append("""
thread_fn hub_supervisor(cfg: gweb::Config, owner_fd: i32) {
    var why: u8[>..] = [];
    while !thread_wait(thread_spawn_contained(hub_thread, cfg, owner_fd), why) {
        print("gweb: the hub thread stopped: ", why, "; restarting it");
        why.clear();
    }
}

thread_fn hub_leave(chans: gweb::Channels) {
    while !net::wait_stop(1000) {}
    gweb::owner_leave(chans);
}

""");
}

// ROUTES, the route patterns in the order route_index numbers them, and the typed jobs:: wrappers.
fn gen_ops_decls(m: u8[>..]&) {
    m.append("\nlet ROUTES = \"");
    var first = true;
    for d in dirs {
        if !d.route && !d.page_html { continue; }
        if !first { m.append("\\n"); }
        first = false;
        var u: u8[>..] = [];
        url_of(u, d.rel);
        lit(m, u);
    }
    m.append("\";\n");
    if !has_jobs { return; }
    m.append("""
fn jobs::enqueue(ctx: const gweb::Ctx&, job: jobs::Job, delay_ms: i64 = 0) -> bool {
    var one: jobs::Job[>..] = [];
    one.push(job);
    var bytes: u8[>..] = [];
    to_bytes(one, bytes);
    return gweb::job_push(bytes, delay_ms);
}

fn jobs::every(s: gweb::Schedules&, name: const u8[:], ms: i64, job: jobs::Job) -> bool {
    var one: jobs::Job[>..] = [];
    one.push(job);
    var bytes: u8[>..] = [];
    to_bytes(one, bytes);
    return gweb::schedule_every(s, name, ms, bytes);
}

fn jobs::cron(s: gweb::Schedules&, name: const u8[:], spec: const u8[:], job: jobs::Job) -> bool {
    var one: jobs::Job[>..] = [];
    one.push(job);
    var bytes: u8[>..] = [];
    to_bytes(one, bytes);
    return gweb::schedule_cron(s, name, spec, bytes);
}
""");
    m.append("\n");
}

// A runner takes jobs until the server stops; job_supervisor restarts it after an abort and counts the job it held
// as a failed attempt.
fn gen_job_threads(m: u8[>..]&) {
    m.append("""
thread_fn job_runner(slot: i64, owner_fd: i32, cfg: gweb::Config) {
    var bytes: u8[>..] = [];
    var sched: u8[>..] = [];
    while !net::stopping() {
        bytes.clear();
        sched.clear();
        let id, attempt, got = gweb::job_take(slot, 250, bytes, sched);
        if !got { continue; }
        var name: u8[>..] = [];
        if sched.len > 0 { format(name, "job ", sched); } else { name.append("job"); }
        var ctx = gweb::job_ctx(slot, owner_fd, id, attempt, name, cfg.hub);
        let batch, decoded = from_bytes<jobs::Job[>..]>(bytes);
        var ok = false;
        if decoded { for j in batch { ok = jobs::run(j, ctx); } }
        gweb::job_done(slot, ok, ctx);
    }
}

thread_fn job_supervisor(slot: i64, owner_fd: i32, cfg: gweb::Config, chans: gweb::Channels) {
    var why: u8[>..] = [];
    while !thread_wait(thread_spawn_contained(job_runner, slot, owner_fd, cfg), why) {
        gweb::job_abandon(slot, why);
        if net::stopping() { break; }
        why.clear();
    }
    gweb::owner_leave(chans);
}
""");
    m.append("\n");
}

// The order: secrets and config, export, signals, listener, ops, state, uploads, the hub, jobs and their schedules,
// workers, handoff, ready, then the waits and the shutdown steps. A start-up failure of a schedule exits before any
// thread runs.
fn gen_main_fn(m: u8[>..]&) {
    m.append("\nfn main() {\n    var cfg = gweb::config_from_args();\n");
    if uses_keys { m.append("    if cfg.auth.keys.n == 0 { print(\"gweb: set GWEB_SECRET (32 to 64 bytes; openssl rand -hex 32)\"); exit(2); }\n"); }
    if has_config { m.append("    if !config::check() { exit(2); }\n"); }
    // Export renders in process: no socket and no workers, but pages that ask the state owner still need it.
    if has_state {
        m.append("    if cfg.export_dir.len > 0 {\n");
        if has_state_init { m.append("        state::init();\n"); }
        m.append("        let chans = gweb::owner_channels(1);\n");
        m.append("        thread_spawn(export_thread, gweb::worker_end(chans, 0), cfg);\n");
        m.append("        gweb::owner_loop<state::Msg, state::Reply>(chans, state::handle);\n        return;\n    }\n");
    } else {
        m.append("    if cfg.export_dir.len > 0 { exit(if run_export(cfg.export_dir, -1) { 0 } else { 1 }); }\n");
    }
    m.append("    net::stop_on_signals(cfg.drain_delay_ms, cfg.drain_ms);\n");
    m.append("""
    let server, inherited = net::listen_inherited(cfg.port, cfg.host, 1024);
    guard server.ok() else { print("gweb: cannot listen on port ", cfg.port, ": ", net::last_error()); exit(1); }
    gweb::ops_init(cfg, ROUTES);
    gweb::inflight_init(cfg.workers, cfg.dev_id != 0);
""");
    if has_state && has_state_init { m.append("    state::init();\n"); }
    // Owner channels: one per worker, then one per job runner, then the hub thread's.
    var users: u8[>..] = [];
    users.append("cfg.workers");
    if has_jobs { users.append(" + cfg.job_runners"); }
    var hub_slot: u8[>..] = [];
    hub_slot.append(users);
    if uses_hub { users.append(" + 1"); }
    if has_state { format(m, "    let chans = gweb::owner_channels(", users, ");\n"); }
    else { m.append("    let chans = gweb::Channels { handle: 0, n: 0 };\n"); }
    m.append("    gweb::prepare_uploads(cfg);\n");
    if uses_hub {
        m.append("    let hb = net::hub();\n    cfg.hub = hb.handle;\n");
        // The hub is not waited for: it ends with the process. Its owner channel leaves once the stop begins.
        if has_state {
            format(m, "    thread_spawn(hub_supervisor, cfg, gweb::worker_end(chans, ", hub_slot, "));\n");
            m.append("    thread_spawn(hub_leave, chans);\n");
        } else { m.append("    thread_spawn(hub_supervisor, cfg, -1);\n"); }
    }
    if has_jobs {
        m.append("    gweb::jobs_init(cfg);\n    var sched = gweb::new_schedules(cfg);\n");
        if has_jobs_schedule { m.append("    jobs::schedule(sched);\n"); }
        m.append("    if sched.bad > 0 { exit(1); }\n");
    }
    m.append("    var ids: i64[>..] = [];\n");
    let wfd = if has_state { "gweb::worker_end(chans, i)" } else { "-1" };
    format(m, "    for i in cfg.workers { ids.push(thread_spawn(supervisor, i, server, ", wfd, ", cfg, chans)); }\n");
    if has_jobs {
        let jfd = if has_state { "gweb::worker_end(chans, cfg.workers + i)" } else { "-1" };
        format(m, "    for i in cfg.job_runners { ids.push(thread_spawn(job_supervisor, i, ", jfd, ", cfg, chans)); }\n");
    }
    m.append("""
    var argv: u8[>..] = [];
    for a in args() { argv.append(a); argv.push(0); }
    net::enable_handoff(server, argv);
    net::ready();
    var up: u8[>..] = [];
    format(up, "gweb: http://localhost:", cfg.port, " (", cfg.workers, " workers)");
    gweb::log_message(gweb::Level.Info, up);
""");
    if has_state { m.append("    gweb::owner_loop<state::Msg, state::Reply>(chans, state::handle);\n"); }
    m.append("    for id in ids { thread_wait(id); }\n");
    if has_jobs {
        m.append("""
    gweb::jobs_stop();
    let dropped = gweb::jobs_queued();
    if dropped > 0 {
        var msg: u8[>..] = [];
        format(msg, "gweb: stopped with ", dropped, " queued jobs dropped");
        gweb::log_message(gweb::Level.Warn, msg);
    }
""");
    }
    if has_state_shutdown { m.append("    state::shutdown();\n"); }
    m.append("    gweb::ops_shutdown();\n    exit(0);\n}\n");
}

// The part of the generated main that the server and the route tests share, up to and including dispatch.
fn gen_main_body(m: u8[>..]&, test: bool) {
    m.append("// Generated by gweb. Do not edit; it is rewritten on every build.\n");
    m.append("import std;\n");
    m.append("import gweb from \""); lit(m, pkg_source(0)); m.append("\";\n");
    m.append("import net from \""); lit(m, pkg_source(1)); m.append("\";\n");
    if uses_sqlite { m.append("import sqlite from \""); lit(m, pkg_source(2)); m.append("\";\n"); }
    m.append("import os;\nimport net.http;\nimport gweb.site.template;\nimport gweb.site.meta;\nimport gweb.site.sitemap;\nimport gweb.http.static;\nimport gweb.ops.owner;\nimport gweb.forms.form;\nimport gweb.auth.csrf;\nimport gweb.forms.valid;\nimport gweb.forms.upload;\nimport gweb.site.errors;\nimport gweb.auth.crypto;\nimport gweb.auth.session;\nimport gweb.auth.rate;\nimport gweb.auth.cors;\nimport gweb.http.cache;\nimport gweb.http.stream;\nimport gweb.http.push;\n");
    if uses_hub { m.append("import net.hub;\n"); }
    m.append("import gweb.ops.log;\n");
    if has_jobs { m.append("import gweb.ops.jobs;\nimport jobs;\n"); }
    if has_locales { m.append("import gweb.site.i18n;\nimport t;\n"); }
    if test { m.append("import gweb.testing;\nimport site;\n"); }
    for d in dirs {
        if d.route { format(m, "import ", d.route_ns, ";\n"); }
        if d.page_html { format(m, "import ", d.page_ns, "_html;\n"); if d.page_goose { format(m, "import ", d.page_ns, ";\n"); } }
        if d.layout { format(m, "import ", d.layout_ns, ";\n"); }
        if d.middleware { format(m, "import ", d.mw_ns, ";\n"); }
        if d.error_html { format(m, "import ", d.error_ns, ";\n"); }
        if d.loading { format(m, "import ", d.loading_ns, ";\n"); }
    }
    if has_not_found { m.append("import nf;\n"); }
    if has_config { m.append("import config;\n"); }
    if has_sitemap { m.append("import smap;\n"); }
    if has_socket { m.append("import socket;\n"); }
    if test { for ns in test_files { format(m, "import ", ns, ";\n"); } }
    if has_state {
        m.append("import state;\n");
        if test { gen_test_ask(m); }
        else {
            m.append("fn state::ask(ctx: const gweb::Ctx&, msg: state::Msg) -> state::Reply, bool {\n");
            m.append("    return gweb::owner_call_fd<state::Msg, state::Reply>(ctx.owner_fd, msg);\n}\n");
        }
    }
    m.append("\n");
    gen_static(m);
    gen_asset_url(m);
    m.append("\n");
    for d, i in dirs {
        if d.route { gen_route_fn(m, d, i); }
        if d.page_html { gen_page_fn(m, d, i); }
    }
    m.append("\n");
    gen_error_reply(m);
    m.append("\n");
    gen_sitemap(m);
    gen_finish(m);
    m.append("\n");
    gen_dispatch(m);
    gen_ops_decls(m);
}

fn gen_main() -> u8[>..] {
    var m: u8[>..] = [];
    gen_main_body(m, false);
    m.append("\n");
    gen_export(m);
    m.append("""
thread_fn worker(slot: i64, server: net::Socket, owner_fd: i32, cfg: gweb::Config) {
    gweb::run_worker(slot, server, owner_fd, cfg, ROUTES, dispatch, static_bytes);
}

// D12: answers the request the dead worker held. Runs contained, so a crash here only costs this attempt.
// The head buffer lives as long as the Request parsed from it. Returning normally means the reply is sent.
thread_fn crash_reply(slot: i64, cfg: gweb::Config, attempt: i64) {
    var head: u8[>..] = [];
    var abort_text: u8[>..] = [];
    gweb::crash_info(slot, head, abort_text);
    let req, parsed = http::parse_request(head);
    match parsed {
        Ready => {
            var ctx = gweb::new_ctx(slot, -1);
            var res = http::new_response();
            error_reply(gweb::inflight_route_of(slot), attempt, req, ctx, res, abort_text);
            ctx.auth = cfg.auth;
            gweb::apply_cookies(ctx, res);
            gweb::apply_security(ctx, res, cfg);
            gweb::dev_inject(res, cfg.dev_id, "");
            http::send_response(gweb::inflight_conn(slot), res, req.method == http::Method.Head, false);
        },
        _ => gweb::plain_500(slot),
    }
}

// After an abort with a request in flight: attempt 1, then 2, then a fixed plain 500; a crash during a gweb::fail
// render (phase 1) skips attempt 1. Then the dead worker's loop is freed, which closes its connections.
thread_fn supervisor(slot: i64, server: net::Socket, owner_fd: i32, cfg: gweb::Config, chans: gweb::Channels) {
    var why: u8[>..] = [];
    while !thread_wait(thread_spawn_contained(worker, slot, server, owner_fd, cfg), why) {
        var msg: u8[>..] = [];
        format(msg, "gweb: worker ", slot, " stopped: ", why, if net::stopping() { "" } else { "; restarting it" });
        gweb::log_message(gweb::Level.Error, msg);
        if gweb::inflight_pending(slot) {
            gweb::inflight_set_why(slot, why);
            var attempt = if gweb::inflight_phase_of(slot) == 1 { 2 } else { 1 };
            var answered = false;
            while attempt <= 2 && !answered {
                var attempt_why: u8[>..] = [];
                answered = thread_wait(thread_spawn_contained(crash_reply, slot, cfg, attempt), attempt_why);
                attempt += 1;
            }
            if !answered { gweb::plain_500(slot); }
        }
        gweb::inflight_release(slot);
        if net::stopping() { break; }
        why.clear();
    }
    gweb::owner_leave(chans);
}

""");
    if uses_hub { gen_hub_thread(m); }
    if has_jobs { m.append("\n"); gen_job_threads(m); }
    gen_main_fn(m);
    return m;
}


// state::ask without a channel: the same encode and decode as the owner transport, then a direct call on main.
fn gen_test_ask(m: u8[>..]&) {
    m.append("fn state::ask(ctx: const gweb::Ctx&, msg: state::Msg) -> state::Reply, bool {\n");
    m.append("    var one: state::Msg[>..] = [];\n    one.push(msg);\n");
    m.append("    var bytes: u8[>..] = [];\n    to_bytes(one, bytes);\n");
    m.append("    let ms, mok = from_bytes<state::Msg[>..]>(bytes);\n");
    m.append("    if !mok { return state::Reply { .. }, false; }\n");
    m.append("    var replies: state::Reply[>..] = [];\n");
    m.append("    for m in ms { replies.push(state::handle(m)); }\n");
    m.append("    var out: u8[>..] = [];\n    to_bytes(replies, out);\n");
    m.append("    let rs, rok = from_bytes<state::Reply[>..]>(out);\n");
    m.append("    if rok { for r in rs { return copy(r), true; } }\n");
    m.append("    return state::Reply { .. }, false;\n}\n");
}

// The site:: helpers a test calls; each sends one request through dispatch and static_bytes.
let SITE_PLAIN = ["get", "head", "delete"];
let SITE_PLAIN_METHOD = ["GET", "HEAD", "DELETE"];
let SITE_BODY = ["post_form", "post_json", "put_json", "patch_json"];
let SITE_BODY_METHOD = ["POST", "POST", "PUT", "PATCH"];
let SITE_BODY_TYPE = ["application/x-www-form-urlencoded", "application/json", "application/json", "application/json"];

fn gen_site_fns(m: u8[>..]&) {
    for i in SITE_PLAIN.len {
        format(m, "fn site::", SITE_PLAIN[i], "(t: gweb::Tester&, target: const u8[:]) -> http::Response {\n");
        format(m, "    return gweb::test_send(t, \"", SITE_PLAIN_METHOD[i], "\", target, \"\", \"\", dispatch, static_bytes);\n}\n");
    }
    for i in SITE_BODY.len {
        format(m, "fn site::", SITE_BODY[i], "(t: gweb::Tester&, target: const u8[:], body: const u8[:]) -> http::Response {\n");
        format(m, "    return gweb::test_send(t, \"", SITE_BODY_METHOD[i], "\", target, body, \"", SITE_BODY_TYPE[i], "\", dispatch, static_bytes);\n}\n");
    }
    m.append("fn site::request(t: gweb::Tester&, method: const u8[:], target: const u8[:], body: const u8[:], content_type: const u8[:]) -> http::Response {\n");
    m.append("    return gweb::test_send(t, method, target, body, content_type, dispatch, static_bytes);\n}\n");
}

fn gen_test_main() -> u8[>..] {
    var m: u8[>..] = [];
    gen_main_body(m, true);
    m.append("\n");
    gen_site_fns(m);
    m.append("\nfn main() {\n    var gw_t = gweb::Tester { .. };\n    var before = 0;\n");
    if has_state && has_state_init { m.append("    state::init();\n"); }
    for f in test_fns {
        format(m, "    gw_t.name.clear();\n    gw_t.name.append(\"", f.ns, "::", f.name, "\");\n");
        format(m, "    print(\"== ", f.ns, "::", f.name, "\");\n    before = gw_t.failures;\n    ", f.ns, "::", f.name, "(gw_t);\n");
        format(m, "    if gw_t.failures == before { print(\"ok ", f.ns, "::", f.name, "\"); }\n");
    }
    format(m, "    print(\"routes: ", test_fns.len, " tests, \", gw_t.checks, \" checks, \", gw_t.failures, \" failed\");\n");
    m.append("    if gw_t.failures > 0 { exit(1); }\n}\n");
    return m;
}

// ---------------------------------------------------------------- gen

fn goose_web_home() -> u8[>..] {
    var h: u8[>..] = [];
    if env("GWEB_HOME", h) && h.len > 0 {
        while h.len > 1 && h[h.len - 1] == '/' { h.pop(); }
        return h;
    }
    h.clear();
    resource_dir(h);
    while h.len > 1 && h[h.len - 1] == '/' { h.pop(); }
    var probe: u8[>..] = [];
    format(probe, h, "/gweb.goose");
    if !file_exists(probe) { h.clear(); }
    return h;
}

// Precedence: $GWEB_SRC, $GWEB_NET or $GWEB_SQLITE, then the checkout and its siblings, then the pin.
fn pkg_source(which: i32) -> u8[>..] {
    var s: u8[>..] = [];
    let var_name = if which == 0 { "GWEB_SRC" } else if which == 1 { "GWEB_NET" } else { "GWEB_SQLITE" };
    if env(var_name, s) && s.len > 0 { return s; }
    s.clear();
    let home = goose_web_home();
    if home.len > 0 {
        if which == 0 { s.append(home); return s; }
        let sibling = if which == 1 { "/../goose-net" } else { "/../goose-sqlite" };
        var probe: u8[>..] = [];
        format(probe, home, sibling, if which == 1 { "/net.goose" } else { "/sqlite.goose" });
        if file_exists(probe) { format(s, home, sibling); return s; }
    }
    if which == 0 { return copy(pins::PIN_WEB); }
    if which == 1 { return copy(pins::PIN_NET); }
    return copy(pins::PIN_SQLITE);
}

let RT_PRETTY = embed_file("../client/gwi.js");
let RT_MIN = embed_file("../client/gwi.min.js");
let RT_FRAG_PRETTY = embed_file("../client/gwf.js");
let RT_FRAG_MIN = embed_file("../client/gwf.min.js");
let RT_HTTP_PRETTY = embed_file("../client/gwh.js");
let RT_HTTP_MIN = embed_file("../client/gwh.min.js");
let RT_LIFE_PRETTY = embed_file("../client/gwl.js");
let RT_LIFE_MIN = embed_file("../client/gwl.min.js");
let RT_MODS_PRETTY = embed_file("../client/gwm.js");
let RT_MODS_MIN = embed_file("../client/gwm.min.js");
let RT_CHILD_PRETTY = embed_file("../client/gwc.js");
let RT_CHILD_MIN = embed_file("../client/gwc.min.js");
let RT_TRANS_PRETTY = embed_file("../client/gwt.js");
let RT_TRANS_MIN = embed_file("../client/gwt.min.js");
let RT_NAV_PRETTY = embed_file("../client/gwn.js");
let RT_NAV_MIN = embed_file("../client/gwn.min.js");
let RT_STORE_PRETTY = embed_file("../client/gws.js");
let RT_STORE_MIN = embed_file("../client/gws.min.js");
let RT_SSE_PRETTY = embed_file("../client/gwe.js");
let RT_SSE_MIN = embed_file("../client/gwe.min.js");

// which: 0 is gwi.js (the core), 1 is gwf.js (fragments), 2 is gwh.js (typed fetch), 3 is gwl.js (lifecycle), 4 is gwm.js (modifiers), 5 is gwc.js (child components), 6 is gwn.js (client navigation), 7 is gws.js (stores), 8 is gwt.js (transitions), 9 is gwe.js (server push).
fn runtime_js(which: i64, min: bool, out: u8[>..]&) {
    let home = goose_web_home();
    if home.len > 0 {
        var p: u8[>..] = [];
        let base = if which == 1 { "/client/gwf" } else if which == 2 { "/client/gwh" } else if which == 3 { "/client/gwl" } else if which == 4 { "/client/gwm" } else if which == 5 { "/client/gwc" } else if which == 6 { "/client/gwn" } else if which == 7 { "/client/gws" } else if which == 8 { "/client/gwt" } else if which == 9 { "/client/gwe" } else { "/client/gwi" };
        format(p, home, base, if min { ".min.js" } else { ".js" });
        if read(p, out) { return; }
    }
    out.clear();
    if which == 1 { out.append(if min { RT_FRAG_MIN } else { RT_FRAG_PRETTY }); }
    else if which == 2 { out.append(if min { RT_HTTP_MIN } else { RT_HTTP_PRETTY }); }
    else if which == 3 { out.append(if min { RT_LIFE_MIN } else { RT_LIFE_PRETTY }); }
    else if which == 4 { out.append(if min { RT_MODS_MIN } else { RT_MODS_PRETTY }); }
    else if which == 5 { out.append(if min { RT_CHILD_MIN } else { RT_CHILD_PRETTY }); }
    else if which == 6 { out.append(if min { RT_NAV_MIN } else { RT_NAV_PRETTY }); }
    else if which == 7 { out.append(if min { RT_STORE_MIN } else { RT_STORE_PRETTY }); }
    else if which == 8 { out.append(if min { RT_TRANS_MIN } else { RT_TRANS_PRETTY }); }
    else if which == 9 { out.append(if min { RT_SSE_MIN } else { RT_SSE_PRETTY }); }
    else { out.append(if min { RT_MIN } else { RT_PRETTY }); }
}

let EMBEDDED_VERSION = embed_file("../VERSION");

fn print_version() {
    var out: u8[>..] = [];
    format(out, "gweb ", trim(EMBEDDED_VERSION), "\n");
    format(out, "web     ", pkg_source(0), "\n");
    format(out, "net     ", pkg_source(1), "\n");
    format(out, "sqlite  ", pkg_source(2), "\n");
    write_stdout(out);
}

fn check_version() {
    let home = goose_web_home();
    if home.len == 0 { return; }
    var path: u8[>..] = [];
    format(path, home, "/VERSION");
    var file: u8[>..] = [];
    read(path, file);
    if trim(file) != trim(EMBEDDED_VERSION) {
        var msg: u8[>..] = [];
        format(msg, "gweb: built from ", trim(EMBEDDED_VERSION), ", but ", home, " is ", trim(file), ": rebuild gweb\n");
        write_stderr(msg);
        exit(1);
    }
}

// ---------------------------------------------------------------- CSS minification

fn css_space(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 12; }

fn css_lower(c: u8) -> u8 { if c >= 'A' && c <= 'Z' { return c + 32; } return c; }

fn css_ident(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-';
}

// Index just past the string that opens at i, or -1 when it never closes.
fn css_string_end(src: const u8[:], i: i64) -> i64 {
    let q = src[i];
    var k = i + 1;
    while k < src.len {
        if src[k] == '\\' { k += 2; continue; }
        if src[k] == q { return k + 1; }
        if src[k] == '\n' { return -1; }
        k += 1;
    }
    return -1;
}

// i is just past "url(". A quoted argument may hold a ")".
fn css_url_end(src: const u8[:], i: i64) -> i64 {
    var k = i;
    while k < src.len {
        let c = src[k];
        if c == '"' || c == '\'' {
            let e = css_string_end(src, k);
            if e < 0 { return -1; }
            k = e;
            continue;
        }
        if c == '\\' { k += 2; continue; }
        if c == ')' { return k + 1; }
        k += 1;
    }
    return -1;
}

// Writes the space that pending whitespace stands for, unless a neighbour makes it meaningless. The
// combinators > ~ + keep their spaces inside parentheses, where + is calc's operator and > a range
// comparison. A space before ":" stays: "a :hover" and "a:hover" select different elements.
fn css_gap(res: u8[>..]&, next: u8, paren: i64, lit_end: bool) {
    if res.len == 0 { return; }
    let last = res[res.len - 1];
    if !lit_end && (last == '{' || last == '}' || last == ';' || last == ',' || last == ':'
                    || (paren == 0 && (last == '>' || last == '~' || last == '+'))) { return; }
    if next == '{' || next == '}' || next == ';' || next == ',' || (paren == 0 && (next == '>' || next == '~' || next == '+')) { return; }
    res.push(' ');
}

// Appends the minified src to out and returns true; returns false, leaving out alone, when strings, url(),
// comments, parentheses or braces do not balance, so a file this cannot read is served as written.
fn minify_css(src: const u8[:], out: u8[>..]&) -> bool {
    var res: u8[>..] = [];
    var depth = 0;
    var paren = 0;
    var pending = false;      // whitespace or a dropped comment came since the last byte written
    var lit_end = false;      // the last bytes written were copied verbatim, so they say nothing about the next space
    var i = 0;
    while i < src.len {
        let c = src[i];
        if css_space(c) { pending = true; i += 1; continue; }
        if c == '/' && i + 1 < src.len && src[i + 1] == '*' {
            var e = i + 2;
            while e + 1 < src.len && !(src[e] == '*' && src[e + 1] == '/') { e += 1; }
            if e + 1 >= src.len { return false; }
            if i + 2 < src.len && src[i + 2] == '!' {
                if pending { css_gap(res, '/', paren, lit_end); pending = false; }
                res.append(src[i..e + 2]);
                lit_end = true;
            } else {
                pending = true;
            }
            i = e + 2;
            continue;
        }
        let spaced = pending;
        if pending { css_gap(res, c, paren, lit_end); pending = false; }
        if c == '"' || c == '\'' {
            let e = css_string_end(src, i);
            if e < 0 { return false; }
            res.append(src[i..e]);
            lit_end = true;
            i = e;
            continue;
        }
        if c == '\\' && i + 1 < src.len {
            res.push(c);
            res.push(src[i + 1]);
            lit_end = true;
            i += 2;
            continue;
        }
        let n = res.len;
        if c == '(' && !spaced && n >= 3 && css_lower(res[n - 3]) == 'u' && css_lower(res[n - 2]) == 'r' && css_lower(res[n - 1]) == 'l'
           && (n == 3 || !css_ident(res[n - 4])) {
            let e = css_url_end(src, i + 1);
            if e < 0 { return false; }
            res.append(src[i..e]);
            lit_end = true;
            i = e;
            continue;
        }
        if c == '{' { depth += 1; }
        if c == '}' { depth -= 1; if depth < 0 { return false; } }
        if c == '(' { paren += 1; }
        if c == ')' { paren -= 1; if paren < 0 { return false; } }
        res.push(c);
        lit_end = false;
        i += 1;
    }
    if depth != 0 || paren != 0 { return false; }
    out.append(res);
    return true;
}

fn css_case(src: const u8[:], ok: bool, want: const u8[:]) -> bool {
    var out: u8[>..] = [];
    let got = minify_css(src, out);
    if got == ok && (!ok || out == want) && (ok || out.len == 0) { return true; }
    var m: u8[>..] = [];
    format(m, "test-css: for '", src, "' wanted ", if ok { "true" } else { "false" }, " ", want, ", got ", if got { "true" } else { "false" }, " ", out, "\n");
    write_stderr(m);
    return false;
}

// gweb test-css: the minifier's cases; it needs no project.
fn test_css() -> bool {
    var ok = true;
    ok = css_case("p { color: red; }\n", true, "p{color:red;}") && ok;
    ok = css_case("a::after { content: \"a  b\"; }", true, "a::after{content:\"a  b\";}") && ok;
    ok = css_case("a { content: 'x  ; }'; }", true, "a{content:'x  ; }';}") && ok;
    ok = css_case("a { background: url( x ) no-repeat; }", true, "a{background:url( x ) no-repeat;}") && ok;
    ok = css_case("a { background: URL(\"a b)\" ) }", true, "a{background:URL(\"a b)\" )}") && ok;
    ok = css_case("a { width: calc(1px + 2px); }", true, "a{width:calc(1px + 2px);}") && ok;
    ok = css_case("a { margin: calc( 1px - 2px ) 0 }", true, "a{margin:calc( 1px - 2px ) 0}") && ok;
    ok = css_case("/*! keep */ a { b: c } /* drop */", true, "/*! keep */ a{b:c}") && ok;
    ok = css_case("a/* x */b { c: d }", true, "a b{c:d}") && ok;
    ok = css_case("a  >  b ~ c + d , e { f: g }", true, "a>b~c+d,e{f:g}") && ok;
    ok = css_case("a :hover { b: c }", true, "a :hover{b:c}") && ok;
    ok = css_case("@media screen and (min-width: 5px) { a { b: c; } d { e: f } }", true,
                  "@media screen and (min-width:5px){a{b:c;}d{e:f}}") && ok;
    ok = css_case("a { b: c;", false, "") && ok;
    ok = css_case("a { b: c } }", false, "") && ok;
    ok = css_case("a { b: \"c; }", false, "") && ok;
    ok = css_case("a { b: c } /* open", false, "") && ok;
    ok = css_case("a { b: url(x }", false, "") && ok;
    if ok { write_stdout("test-css: ok\n"); }
    return ok;
}

// ---------------------------------------------------------------- embedded variants

fn gzippable(ctype: const u8[:]) -> bool {
    return starts_with(ctype, "text/") || starts_with(ctype, "application/json") || starts_with(ctype, "application/xml")
        || starts_with(ctype, "image/svg+xml") || starts_with(ctype, "application/wasm");
}

// The bytes a static serves: its file, minified when min says so.
fn served_bytes(s: const Static&, out: u8[>..]&) -> bool {
    var raw: u8[>..] = [];
    if !read(s.file, raw) { return false; }
    if !s.min { out.append(raw); return true; }
    return minify_css(raw, out);
}

// Writes what the binary embeds besides public/ and _gw/: minified CSS and gzip variants. Runs once every
// static is known, because a gz index counts on from statics.len.
fn gen_variants() {
    var dir: u8[>..] = [];
    format(dir, gen_root, "/_pub");
    make_dir(dir);
    dir.clear();
    format(dir, gen_root, "/_gz");
    make_dir(dir);
    var next = statics.len;
    for &s, i in statics {
        var data: u8[>..] = [];
        if !served_bytes(s, data) { continue; }
        if s.min {
            var p: u8[>..] = [];
            format(p, gen_root, "/_pub/", i, ".css");
            write(p, data);
            s.embed.append(p);
        }
        if data.len < 1024 || !gzippable(s.ctype) { continue; }
        var z: u8[>..] = [];
        // A variant that saves under a tenth costs a header and a second ETag for nothing.
        if c_gzip(data, z) == 0 || z.len * 10 > data.len * 9 { continue; }
        var zp: u8[>..] = [];
        format(zp, gen_root, "/_gz/", i, ".gz");
        write(zp, z);
        s.gz = next;
        next += 1;
    }
}

// ---------------------------------------------------------------- components

fn push_gw_static(url: const u8[:], file: const u8[:], data: const u8[:]) {
    var s = Static { url: "", file: "", ctype: "text/javascript; charset=utf-8", etag: "", hashed: "", embed: "", min: false, gz: -1 };
    s.url.append(url);
    s.file.append(file);
    s.etag = etag_of(data);
    s.hashed = hashed_url(s.url, s.etag);
    statics.push(s);
}

fn gen_runtime_file(which: i64, name: const u8[:], dev: bool, gw_dir: const u8[:]) {
    var rt: u8[>..] = [];
    runtime_js(which, !dev, rt);
    var js_path: u8[>..] = [];
    format(js_path, gw_dir, "/", name);
    write(js_path, rt);
    var url: u8[>..] = [];
    format(url, "/_gw/", name);
    push_gw_static(url, js_path, rt);
}

// gwi.js serves components and fragments (gwf.js imports it); gwf.js only when the site uses fragments.
fn gen_runtime(dev: bool) {
    var gw_dir: u8[>..] = [];
    format(gw_dir, gen_root, "/_gw");
    make_dir(gw_dir);
    gen_runtime_file(0, "gwi.js", dev, gw_dir);
    if uses_fragments { gen_runtime_file(1, "gwf.js", dev, gw_dir); }
    if uses_http { gen_runtime_file(2, "gwh.js", dev, gw_dir); }
    if uses_life { gen_runtime_file(3, "gwl.js", dev, gw_dir); }
    if uses_mods { gen_runtime_file(4, "gwm.js", dev, gw_dir); }
    if uses_children { gen_runtime_file(5, "gwc.js", dev, gw_dir); }
    if uses_boost { gen_runtime_file(6, "gwn.js", dev, gw_dir); }
    if uses_stores || uses_sse { gen_runtime_file(7, "gws.js", dev, gw_dir); }
    if uses_trans { gen_runtime_file(8, "gwt.js", dev, gw_dir); }
    if uses_sse { gen_runtime_file(9, "gwe.js", dev, gw_dir); }
}

// The indices of component_names, each component after the components its markup calls with @Name( (a cycle is cut at
// the first component of it; that one reports `components cannot contain themselves`).
fn component_order() -> i64[>..] {
    let n = component_names.len;
    var dep: i64[>..] = [];                // dep[a * n + b] is 1 when a calls b
    for k in n * n { dep.push(0); }
    for a in n {
        var src: u8[>..] = [];
        if !read(component_paths[a], src) { continue; }
        for i in src.len {
            if src[i] != '@' { continue; }
            let o = tscan::call_open(src, i);
            if o < 0 { continue; }
            let b = component_index(src[i + 1..o]);
            if b >= 0 && b != a { dep[a * n + b] = 1; }
        }
    }
    var done: i64[>..] = [];
    for k in n { done.push(0); }
    var order: i64[>..] = [];
    while order.len < n {
        var pick = -1;
        for a in n {
            if done[a] == 1 || pick >= 0 { continue; }
            var ready = true;
            for b in n { if dep[a * n + b] == 1 && done[b] == 0 { ready = false; } }
            if ready { pick = a; }
        }
        if pick < 0 { for a in n { if done[a] == 0 && pick < 0 { pick = a; } } }
        done[pick] = 1;
        order.push(pick);
    }
    return order;
}

// Tells component.goose which components exist; it records each one's props as it compiles it.
fn registry_begin() {
    component::registry_clear();
    for n in component_names { component::registry_add(n); }
}

// Every store is compiled before any component: a component reads what its stores left in the registry.
fn gen_stores(dev: bool, gw_dir: const u8[:]) {
    for n in store_names {
        var path: u8[>..] = [];
        format(path, "stores/", n, ".gshtml");
        var src: u8[>..] = [];
        if !read(path, src) { continue; }
        var g: u8[>..] = [];
        var j: u8[>..] = [];
        var e: u8[>..] = [];
        var w: u8[>..] = [];
        let compiled = component::compile_store(n, path, src, !dev, g, j, e, w);
        uses_stores = true;
        emit_component_warnings(w);
        if !compiled {
            print_compiler(e);
            note_errors(e);
            for c in e { if c == '\n' { component_errors += 1; } }
            if e.len == 0 { component_errors += 1; }
        }
        var dst: u8[>..] = [];
        format(dst, gen_root, "/", n, ".goose");
        write(dst, g);
        format(map_text, n, ".goose\t", path, "\n");
        dst.clear();
        format(dst, gw_dir, "/", n, ".js");
        write(dst, j);
        var url: u8[>..] = [];
        format(url, "/_gw/", n, ".js");
        push_gw_static(url, dst, j);
    }
}

// A hashed URL may not collide with another file's URLs or a literal route.
fn check_hashed() {
    for s, i in statics {
        for o, k in statics {
            if k == i { continue; }
            let hit_url = s.hashed == o.url;
            let hit_hash = k > i && s.hashed == o.hashed;
            if !hit_url && !hit_hash { continue; }
            var m: u8[>..] = [];
            format(m, "this file's hashed URL ", s.hashed, " is taken by ");
            if hit_url { m.append(o.url); } else { m.append(o.hashed); }
            err(s.file, 0, m);
        }
        for d in dirs {
            if !d.route && !d.page_html { continue; }
            var u: u8[>..] = [];
            url_of(u, d.rel);
            if s.hashed == u {
                var m: u8[>..] = [];
                format(m, "this file's hashed URL ", s.hashed, " is taken by ", u);
                err(s.file, 0, m);
            }
        }
    }
}

// gen goes on after translator errors, so the Goose compiler reports its errors too.
fn gen_components(dev: bool) {
    component_lines.clear();
    component_reactive.clear();
    component_props.clear();
    if component_names.len == 0 && store_names.len == 0 { return; }
    var gw_dir: u8[>..] = [];
    format(gw_dir, gen_root, "/_gw");
    make_dir(gw_dir);
    registry_begin();
    gen_stores(dev, gw_dir);
    for k in component_names.len { component_lines.push(0); component_reactive.push(0); }
    for oi in component_order() {
        let n = component_names[oi];
        let path = component_paths[oi];
        var src: u8[>..] = [];
        if !read(path, src) { continue; }
        var lines = 1;
        for c in src { if c == '\n' { lines += 1; } }
        component_lines[oi] = lines;
        scan_targets(path, src, -1);
        var g: u8[>..] = [];
        var j: u8[>..] = [];
        var e: u8[>..] = [];
        var w: u8[>..] = [];
        let compiled = component::compile(n, path, src, !dev, g, j, e, w);
        if component::is_reactive() {
            component_reactive[oi] = 1;
            let props = component::props_of();
            for l in split(props, '\n') {
                if l.len > 0 { format(component_props, n, "\t", l, "\n"); }
            }
        }
        emit_component_warnings(w);
        if component::http_used() != 0 { uses_http = true; }
        if component::life_used() != 0 { uses_life = true; }
        if component::mods_used() != 0 { uses_mods = true; }
        if component::trans_used() != 0 { uses_trans = true; }
        if component::children_used() != 0 { uses_children = true; }
        for l in split(component::http_urls(), '\n') {
            let f = split(l, '\t');
            if f.len != 3 || f[2].len >= 512 { continue; }
            let ln, ok = parse_int(f[1]);
            var t = Target { path: "", line: ln, url: "", name: "", post: f[0] == "POST", own: -1 };
            t.path.append(path);
            t.url.append(f[2]);
            http_calls.push(t);
        }
        if !compiled {
            print_compiler(e);
            note_errors(e);
            for c in e { if c == '\n' { component_errors += 1; } }
            if e.len == 0 { component_errors += 1; }
        }
        var dst: u8[>..] = [];
        format(dst, gen_root, "/", n, ".goose");
        write(dst, g);
        format(map_text, n, ".goose\t", path, "\n");
        dst.clear();
        format(dst, gw_dir, "/", n, ".js");
        write(dst, j);
        var url: u8[>..] = [];
        format(url, "/_gw/", n, ".js");
        push_gw_static(url, dst, j);
    }
}

fn gen(dev: bool, root: const u8[:]) -> bool {
    has_locales = false;
    locale_notes.clear();
    locale_count = 0;
    scan();
    if errors > 0 { return false; }
    gen_root.clear();
    gen_root.append(root);
    c_remove_tree(root);
    make_dir(root);
    map_text.clear();
    srcmap_text.clear();
    uses_sqlite = false;
    uses_keys = false;
    component_errors = 0;
    uses_fragments = false;
    uses_boost = false;
    uses_http = false;
    uses_mods = false;
    uses_trans = false;
    uses_sse = false;
    uses_life = false;
    uses_children = false;
    uses_stores = false;
    targets.clear();
    http_calls.clear();
    gen_components(dev);
    if is_dir("locales") { gen_locales(); }
    if is_dir("lib") { scan_lib_for_sqlite("lib"); }
    uses_hub = has_socket;
    scan_for_hub("app");
    if is_dir("lib") { scan_for_hub("lib"); }
    if is_dir("lib") {
        var lib_link: u8[>..] = [];
        format(lib_link, root, "/lib");
        c_symlink("../lib", lib_link);
    }
    // A package's lib/ is linked at <root>/NAME, so its code writes import NAME.module;
    for pk in pkgs {
        var lib: u8[>..] = [];
        format(lib, pk.dir, "/lib");
        if !is_dir(lib) { continue; }
        scan_lib_for_sqlite(lib);
        var pkg_link: u8[>..] = [];
        format(pkg_link, root, "/", pk.name);
        c_symlink(lib, pkg_link);
    }
    for &d, di in dirs {
        if d.route {
            var src: u8[>..] = [];
            app_path(src, d, "route.goose");
            var code: u8[>..] = [];
            if copy_prefixed_forms(src, d.route_ns, code, true) {
                d.max_upload = max_upload_const(code);
                for k in 7 { if defines(code, METHODS[k]) { d.methods |= 1 << k; } }
                d.csrf_const = csrf_const(src, code, true);
                if d.methods == 0 { err(src, 0, "route.goose defines none of fn GET(, POST(, PUT(, PATCH(, DELETE(, HEAD(, OPTIONS("); }
            }
        }
        if d.middleware {
            var src: u8[>..] = [];
            app_path(src, d, "middleware.goose");
            var code: u8[>..] = [];
            if copy_prefixed(src, d.mw_ns, code) {
                d.has_before = defines(code, "before");
                d.has_after = defines(code, "after");
                if !d.has_before && !d.has_after { err(src, 0, "middleware.goose defines neither fn before( nor fn after("); }
            }
        }
        if d.layout {
            var src: u8[>..] = [];
            app_path(src, d, "layout.html");
            var imports: u8[>..] = [];
            var frags: u8[>..] = [];
            var text: u8[>..] = [];
            if read_src(src, text) { d.layout_csrf = mentions_csrf(text); if mentions_keys(text) { uses_keys = true; } }
            add_default_imports(imports);
            gen_template(src, d.layout_ns, d.layout_ns,
                         "fn render<F>(out: u8[>..]&, req: const http::Request&, ctx: const gweb::Ctx&)", imports, K_LAYOUT, -1, frags);
        }
        if d.error_html {
            var src: u8[>..] = [];
            app_path(src, d, "error.html");
            var imports: u8[>..] = [];
            var frags: u8[>..] = [];
            var text: u8[>..] = [];
            if read_file(src, text) { d.error_csrf = mentions_csrf(text); }
            add_default_imports(imports);
            imports.append("import gweb.site.errors; ");
            gen_template(src, d.error_ns, d.error_ns,
                         "fn render(out: u8[>..]&, req: const http::Request&, ctx: const gweb::Ctx&, err: const gweb::ErrorInfo&)", imports, K_ERROR, -1, frags);
        }
        if d.loading {
            var src: u8[>..] = [];
            app_path(src, d, "loading.html");
            var imports: u8[>..] = [];
            var frags: u8[>..] = [];
            add_default_imports(imports);
            gen_template(src, d.loading_ns, d.loading_ns,
                         "fn render(out: u8[>..]&, req: const http::Request&, ctx: const gweb::Ctx&)", imports, K_LOADING, -1, frags);
        }
        if d.page_html {
            var imports: u8[>..] = [];
            if d.page_goose {
                var src: u8[>..] = [];
                app_path(src, d, "page.goose");
                var code: u8[>..] = [];
                if copy_prefixed_forms(src, d.page_ns, code, true) {
                    d.max_upload = max_upload_const(code);
                    d.has_load = defines(code, "load");
                    d.has_post = defines(code, "POST");
                    d.has_load_res = takes_res(code, "load");
                    d.has_post_res = takes_res(code, "POST");
                    if d.has_post && !d.has_load { err(src, 0, "fn POST( needs fn load( beside it"); }
                    csrf_const(src, code, false);
                    d.in_sitemap = sitemap_listed(src, code);
                    d.revalidate = revalidate_const(src, code);
                    d.static_paths = defines(code, "static_paths");
                    if mentions_csrf(code) { d.page_csrf = true; }
                    imports_of(code, imports);
                }
            }
            add_default_imports(imports);
            var src: u8[>..] = [];
            app_path(src, d, "page.html");
            var html: u8[>..] = [];
            if read_src(src, html) {
                if mentions_csrf(html) { d.page_csrf = true; }
                if mentions_keys(html) { uses_keys = true; }
            }
            var base: u8[>..] = [];
            format(base, d.page_ns, "_html");
            let sig = if d.has_load { "fn render<P>(out: u8[>..]&, req: const http::Request&, ctx: const gweb::Ctx&, props: const P&)" }
                      else { "fn render(out: u8[>..]&, req: const http::Request&, ctx: const gweb::Ctx&)" };
            var frags: u8[>..] = [];
            gen_template(src, d.page_ns, base, sig, imports, K_PAGE, di, frags);
            d.frags.append(frags);
        }
    }
    for d in dirs {
        if d.revalidate > 0 && starts_token(d) {
            var src: u8[>..] = [];
            app_path(src, d, "page.goose");
            err(src, 0, "a page with REVALIDATE cannot use a CSRF token; its HTML would be shared by every visitor");
        }
    }
    not_found_csrf = false;
    if has_not_found {
        var text: u8[>..] = [];
        if read_src("app/not-found.html", text) { not_found_csrf = mentions_csrf(text); if mentions_keys(text) { uses_keys = true; } }
        var imports: u8[>..] = [];
        add_default_imports(imports);
        var frags: u8[>..] = [];
        gen_template("app/not-found.html", "nf", "nf", "fn render(out: u8[>..]&, req: const http::Request&, ctx: const gweb::Ctx&)", imports, K_NOT_FOUND, -1, frags);
    }
    var code_sm: u8[>..] = [];
    if has_state {
        var code: u8[>..] = [];
        if copy_prefixed("app/state.goose", "state", code) {
            has_state_init = defines(code, "init");
            has_state_shutdown = defines(code, "shutdown");
            for name in ["handle"] { if !defines(code, name) { err("app/state.goose", 0, "state.goose needs fn handle(msg: const Msg&) -> Reply"); } }
            if find(code, "enum Msg") < 0 && find(code, "struct Msg") < 0 { err("app/state.goose", 0, "state.goose needs a type named Msg"); }
            if find(code, "struct Reply") < 0 && find(code, "enum Reply") < 0 { err("app/state.goose", 0, "state.goose needs a type named Reply"); }
        }
    }
    if has_config {
        var code: u8[>..] = [];
        if copy_prefixed("app/config.goose", "config", code) {
            if !defines(code, "check") { err("app/config.goose", 0, "config.goose needs fn check() -> bool"); }
        }
    }
    if has_sitemap && copy_prefixed("app/sitemap.goose", "smap", code_sm) { has_entries = defines(code_sm, "entries"); has_robots = defines(code_sm, "robots"); }
    var code_so: u8[>..] = [];
    if has_socket && copy_prefixed("app/socket.goose", "socket", code_so) {
        socket_open = defines(code_so, "open");
        socket_message = defines(code_so, "message");
        socket_close = defines(code_so, "close");
    }
    if has_jobs {
        var code: u8[>..] = [];
        if copy_prefixed("app/jobs.goose", "jobs", code) {
            has_jobs_schedule = defines(code, "schedule");
            if !defines(code, "run") { err("app/jobs.goose", 0, "jobs.goose needs fn run(job: const Job&, ctx: gweb::Ctx&) -> bool"); }
            if !declares_type(code, "Job") { err("app/jobs.goose", 0, "jobs.goose needs a type named Job"); }
        }
    }
    check_targets();
    check_http();
    if errors > 0 { return false; }
    if component_names.len > 0 || store_names.len > 0 || uses_fragments || uses_boost || uses_trans || uses_sse { gen_runtime(dev); }
    check_hashed();
    gen_variants();
    var main_file: u8[>..] = [];
    format(main_file, root, "/main.goose");
    write(main_file, gen_main());
    var map_file: u8[>..] = [];
    format(map_file, root, "/map.txt");
    write(map_file, map_text);
    var srcmap_file: u8[>..] = [];
    format(srcmap_file, root, "/srcmap.txt");
    var srcmap: u8[>..] = [];
    format(srcmap, "gwmap 1\n", srcmap_text);
    write(srcmap_file, srcmap);
    return errors == 0;
}

// ---------------------------------------------------------------- build

fn goose_cmd(out: u8[>..]&) {
    var g: u8[>..] = [];
    if env("GOOSE", g) && g.len > 0 { shq(out, g); } else { out.append("goose"); }
}

fn rewrite_errors(text: const u8[:], cwd: const u8[:]) -> u8[>..] {
    var cur: u8[>..] = [];
    cur.append(text);
    var abs: u8[>..] = [];
    format(abs, cwd, "/");
    for line in split(map_text, '\n') {
        let gen_name, src, ok = split_once(line, '\t');
        if !ok { continue; }
        for absolute in [true, false] {
            var from: u8[>..] = [];
            if absolute { format(from, abs, gen_root, "/", gen_name); } else { format(from, gen_root, "/", gen_name); }
            var next: u8[>..] = [];
            format_replaced(next, cur, from, src);
            cur.clear();
            cur.append(next);
        }
    }
    var lib_from: u8[>..] = [];
    format(lib_from, abs, gen_root, "/lib/");
    var next: u8[>..] = [];
    format_replaced(next, cur, lib_from, "lib/");
    cur.clear();
    cur.append(next);
    next.clear();
    for pk in pkgs {
        var from: u8[>..] = [];
        var to: u8[>..] = [];
        format(from, abs, gen_root, "/", pk.name, "/");
        format(to, pk.dir, "/lib/");
        format_replaced(next, cur, from, to);
        cur.clear();
        cur.append(next);
        next.clear();
    }
    format_replaced(next, cur, abs, "");
    return component_lines_back(next);
}

// Past the source's last line, a component error is in the generated tail; gw_check lines carry `// gw:line N`.
fn component_lines_back(text: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    var p = 0;
    while p < text.len {
        let k = find(text[p..], "components/");
        if k < 0 { out.append(text[p..]); break; }
        let at = p + k;
        out.append(text[p..at]);
        p = at;
        var done = false;
        for n, i in component_names {
            if done || i >= component_lines.len { continue; }
            var pre: u8[>..] = [];
            format(pre, "components/", n, ".gshtml:");
            if !starts_with(text[at..], pre) { continue; }
            var e = at + pre.len;
            while e < text.len && text[e] >= '0' && text[e] <= '9' { e += 1; }
            let num, ok = parse_int(text[at + pre.len..e]);
            if !ok || num <= component_lines[i] { continue; }
            done = true;
            var gen_path: u8[>..] = [];
            format(gen_path, gen_root, "/", n, ".goose");
            var code: u8[>..] = [];
            var src_line = -1;
            if read_file(gen_path, code) {
                let ls = split(code, '\n');
                if num - 1 < ls.len {
                    let tag = find(ls[num - 1], "// gw:line ");
                    if tag >= 0 {
                        let v, vok = parse_int(trim(ls[num - 1][tag + 11..]));
                        if vok { src_line = v; }
                    }
                }
            }
            if src_line > 0 { format(out, pre, src_line); }
            else { format(out, "generated code for ", component_paths[i]); }
            p = e;
        }
        if !done { out.append("components/"); p = at + "components/".len; }
    }
    return out;
}

fn build(debug: bool, dev: bool) -> bool {
    let t0 = clock();
    last_errors.clear();
    last_warnings.clear();
    warnings = 0;
    if !gen(dev, BUILD_DIR) { return false; }
    var cwd: u8[>..] = [];
    c_cwd(cwd);
    var cmd: u8[>..] = [];
    goose_cmd(cmd);
    cmd.append(" build --color never ");
    if debug { cmd.append("--debug "); }
    cmd.append("-o ");
    var bin: u8[>..] = [];
    format(bin, cwd, "/", BUILD_DIR, "/server");
    shq(cmd, bin);
    cmd.push(' ');
    var main_path: u8[>..] = [];
    format(main_path, cwd, "/", BUILD_DIR, "/main.goose");
    shq(cmd, main_path);
    var out: u8[>..] = [];
    let status = c_run(cmd, out);
    let shown = rewrite_errors(out, cwd);
    if status != 0 {
        print_compiler(shown);
        note_errors(shown);
        if shown.len == 0 {
            say_error("gweb: goose build failed; is goose on PATH, or GOOSE set?");
            note_errors("gweb: goose build failed; is goose on PATH, or GOOSE set?\n");
        }
        return false;
    }
    if component_errors > 0 {
        say_error("gweb: the component errors above stop the build");
        return false;
    }
    var routes = 0;
    var pages = 0;
    for d in dirs { if d.route { routes += 1; } if d.page_html { pages += 1; } }
    var msg: u8[>..] = [];
    format(msg, "gweb: built .gooseweb/server: ", routes, " routes, ", pages, " pages, ", statics.len, " static files (",
           ((clock() - t0) * 10.0) as i64 as f64 / 10.0, " s)");
    if warnings > 0 { format(msg, " (", warnings, " warnings)"); }
    msg.push('\n');
    write_stdout(msg);
    write_stdout(locale_notes);
    return true;
}

// ---------------------------------------------------------------- check, lsp-gen, lsp

// Runs goose check on root/main.goose and prints the mapped errors to stderr. True when goose is happy.
fn check_goose(root: const u8[:]) -> bool {
    var cwd: u8[>..] = [];
    c_cwd(cwd);
    var cmd: u8[>..] = [];
    goose_cmd(cmd);
    cmd.append(" check --color never ");
    var main_path: u8[>..] = [];
    format(main_path, cwd, "/", root, "/main.goose");
    shq(cmd, main_path);
    var out: u8[>..] = [];
    let status = c_run(cmd, out);
    let shown = rewrite_errors(out, cwd);
    write_stderr(shown);
    if status != 0 && shown.len == 0 { write_stderr("gweb: goose check failed; is goose on PATH, or GOOSE set?\n"); }
    return status == 0;
}

// The editor entry: always exits 0, the server reads stderr.
fn lsp_gen_cmd(rest: u8[:][:]) {
    var check = false;
    var k = 0;
    while k < rest.len {
        if rest[k] == "--check" { check = true; k += 1; }
        else if rest[k] == "--overlay" && k + 2 < rest.len {
            overlay_src.append(rest[k + 1]);
            overlay_tmp.append(rest[k + 2]);
            k += 3;
        } else { usage(); }
    }
    if gen(true, LSP_DIR) && check { check_goose(LSP_DIR); }
}

fn check_cmd() -> bool {
    if !gen(false, CHECK_DIR) { return false; }
    var good = component_errors == 0;
    if !check_goose(CHECK_DIR) { good = false; }
    if good { write_stdout("gweb: check passed\n"); }
    return good;
}

let LSP_JS = embed_file("../editor/lsp/server.mjs");

fn self_path(a0: const u8[:]) -> u8[>..] {
    var s: u8[>..] = [];
    if a0.len > 0 && a0[0] == '/' { s.append(a0); return s; }
    if find(a0, "/") >= 0 { format(s, start_cwd, "/", a0); return s; }
    var q: u8[>..] = [];
    var cmd: u8[>..] = [];
    cmd.append("command -v ");
    shq(cmd, a0);
    if c_run(cmd, q) == 0 && q.len > 0 && trim(q)[0] == '/' { s.append(trim(q)); } else { s.append(a0); }
    return s;
}

fn lsp_cmd(a0: const u8[:]) {
    var probe: u8[>..] = [];
    if c_run("command -v node", probe) != 0 { write_stderr("gweb lsp needs node\n"); exit(1); }
    var base: u8[>..] = [];
    var xdg: u8[>..] = [];
    var home: u8[>..] = [];
    if env("XDG_CACHE_HOME", xdg) && xdg.len > 0 { base.append(xdg); }
    else if env("HOME", home) && home.len > 0 { format(base, home, "/.cache"); }
    else { write_stderr("gweb lsp: set HOME or XDG_CACHE_HOME\n"); exit(1); }
    var dir: u8[>..] = [];
    format(dir, base, "/gweb");
    var mk: u8[>..] = [];
    mk.append("mkdir -p ");
    shq(mk, dir);
    c_run(mk, probe);
    var file: u8[>..] = [];
    format(file, dir, "/lsp-", trim(EMBEDDED_VERSION), ".mjs");
    var cur: u8[>..] = [];
    if !read_file(file, cur) || cur != LSP_JS { write(file, LSP_JS); }
    if errors > 0 { exit(1); }
    var cmd: u8[>..] = [];
    cmd.append("node ");
    shq(cmd, file);
    cmd.append(" --gweb ");
    shq(cmd, self_path(a0));
    c_exec(cmd);
    write_stderr("gweb: could not start node\n");
    exit(1);
}

// ---------------------------------------------------------------- test

// Copies tests/<name>.goose as namespace t_<name> and collects its `fn test_` functions.
fn scan_tests() {
    test_files.clear();
    test_fns.clear();
    var names: u8[>..] = [];
    if !list_dir("tests", names) { return; }
    var found: u8[..64][>..<] = [];
    for f in split(names, '\n') {
        if f.len == 0 || f[0] == '.' || !ends_with(f, ".goose") { continue; }
        let n = f[..f.len - 6];
        var ok = n.len > 0 && n.len <= 60 && n[0] >= 'a' && n[0] <= 'z';
        for c in n { if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') { ok = false; } }
        var p: u8[>..] = [];
        format(p, "tests/", f);
        if !ok { err(p, 0, "a test file's name is [a-z][a-z0-9_]*, as in tests/todos.goose"); continue; }
        var t: u8[..64] = "";
        t.append(n);
        found.push(t);
    }
    sort(found) { a, b => compare(a, b) < 0 };
    for n in found {
        var src: u8[>..] = [];
        format(src, "tests/", n, ".goose");
        var ns: u8[..80] = "";
        format(ns, "t_", n);
        var code: u8[>..] = [];
        if !copy_prefixed(src, ns, code) { continue; }
        test_files.push(ns);
        for line in split(code, '\n') {
            if !starts_with(line, "fn test_") { continue; }
            let open = find(line, "(");
            if open < 0 { continue; }
            let name = line[3..open];
            if name.len > 64 || !is_ident(name) { continue; }
            var f = TestFn { ns: "", name: "" };
            f.ns.append(ns);
            f.name.append(name);
            test_fns.push(f);
        }
    }
}

fn route_tests() -> bool {
    scan_tests();
    if errors > 0 { return false; }
    var main_file: u8[>..] = [];
    format(main_file, TEST_DIR, "/routes_main.goose");
    write(main_file, gen_test_main());
    // The site:: helpers are defined from routes_main.goose, as state::ask is; this file gives them a namespace to live in.
    var site_file: u8[>..] = [];
    format(site_file, TEST_DIR, "/site.goose");
    write(site_file, "namespace site;\nimport std;\n");
    var map_file: u8[>..] = [];
    format(map_file, TEST_DIR, "/map.txt");
    write(map_file, map_text);
    var cwd: u8[>..] = [];
    c_cwd(cwd);
    var cmd: u8[>..] = [];
    goose_cmd(cmd);
    cmd.append(" build --color never -o ");
    var bin: u8[>..] = [];
    format(bin, cwd, "/", TEST_DIR, "/routes_test");
    shq(cmd, bin);
    cmd.push(' ');
    var mp: u8[>..] = [];
    format(mp, cwd, "/", main_file);
    shq(cmd, mp);
    var out: u8[>..] = [];
    if c_run(cmd, out) != 0 {
        write_stderr(rewrite_errors(out, cwd));
        write_stderr("gweb test: the route tests did not build\n");
        return false;
    }
    out.clear();
    cmd.clear();
    shq(cmd, bin);
    let status = c_run(cmd, out);
    write_stdout(out);
    if status != 0 { write_stderr("gweb test: the route tests failed\n"); }
    return status == 0;
}

// In the compiler's messages, the parity folder's link to name.goose is the file in the test folder.
fn to_test_dir(fixed: u8[>..]&, parity: const u8[:], n: const u8[:]) {
    var from: u8[>..] = [];
    format(from, parity, "/", n, ".goose");
    var to: u8[>..] = [];
    format(to, TEST_DIR, "/", n, ".goose");
    var next: u8[>..] = [];
    format_replaced(next, fixed, from, to);
    fixed.clear();
    fixed.append(next);
}

fn test_cmd() -> bool {
    if !gen(false, TEST_DIR) { return false; }
    if component_errors > 0 { say_error("gweb test: fix the component errors above"); return false; }
    let has_tests = is_dir("tests");
    if component_names.len == 0 && store_names.len == 0 && !has_tests {
        write_stdout("gweb test: no components/*.gshtml or stores/*.gshtml here\n");
        write_stdout("gweb test: no tests/*.goose here\n");
        return true;
    }
    var ok = true;
    if (component_names.len > 0 || store_names.len > 0) && !component_parity() { ok = false; }
    if has_tests && !route_tests() { ok = false; }
    return ok;
}

fn component_parity() -> bool {
    var probe: u8[>..] = [];
    if c_run("command -v node", probe) != 0 { write_stderr("gweb test needs node\n"); return false; }
    var parity: u8[>..] = [];
    format(parity, TEST_DIR, "/parity");
    make_dir(parity);
    var main: u8[>..] = [];
    main.append("// Generated by gweb test. Prints each case: its name, the state as JSON, the render.\n");
    main.append("import std;\nimport os;\n");
    main.append("import gweb from \""); lit(main, pkg_source(0)); main.append("\";\n");
    main.append("import net from \""); lit(main, pkg_source(1)); main.append("\";\n");
    main.append("import net.http;\nimport gweb.site.template;\n");
    for n in store_names { format(main, "import ", n, ";\n"); }
    for n in component_names { format(main, "import ", n, ";\n"); }
    main.append("fn main() {\n    var out: u8[>..] = [];\n");
    var mjs_components: u8[>..] = [];
    var cases = 0;
    for mode in 2 {
        let compact = mode == 1;
        var dir: u8[>..] = [];
        format(dir, parity, "/js-", if compact { "compact" } else { "pretty" });
        make_dir(dir);
        var rt: u8[>..] = [];
        runtime_js(0, compact, rt);
        var p: u8[>..] = [];
        format(p, dir, "/gwi.real.js");
        write(p, rt);
        p.clear();
        format(p, dir, "/gwi.js");
        write(p, GWI_SHIM);
        var hp: u8[>..] = [];
        runtime_js(2, compact, hp);
        p.clear();
        format(p, dir, "/gwh.js");
        write(p, hp);
        // The parity run starts no timers and has no document to query: a module's life() is a stub here.
        p.clear();
        format(p, dir, "/gwl.js");
        write(p, "export function life() {}\n");
        p.clear();
        format(p, dir, "/gwm.js");
        write(p, "\n");
        p.clear();
        format(p, dir, "/gwt.js");
        write(p, "\n");
        var cp: u8[>..] = [];
        runtime_js(5, compact, cp);
        p.clear();
        format(p, dir, "/gwc.js");
        write(p, cp);
        var sp: u8[>..] = [];
        runtime_js(7, compact, sp);
        p.clear();
        format(p, dir, "/gws.js");
        write(p, sp);
        registry_begin();
        // The stores first: a component reads what its stores leave in the registry.
        for n in store_names {
            var path: u8[>..] = [];
            format(path, "stores/", n, ".gshtml");
            var src: u8[>..] = [];
            if !read(path, src) { return false; }
            var g: u8[>..] = [];
            var j: u8[>..] = [];
            var e: u8[>..] = [];
            var w: u8[>..] = [];
            component::compile_store(n, path, src, compact, g, j, e, w);
            p.clear();
            format(p, dir, "/", n, ".js");
            write(p, j);
            if mode == 1 { continue; }
            if mjs_components.len > 0 { mjs_components.push(','); }
            format(mjs_components, "\"", n, "\"");
            let tests = component::test_names();
            let test_takes = component::test_args();
            let takes = split(test_takes, '\n');
            for t, ti in concat(split("zero\n", '\n')[..1], split(tests, '\n')) {
                if t.len == 0 { continue; }
                cases += 1;
                format(main, "    { var p = ", n, "::Props { .. }; var s = ", n, "::gw_init(p); ");
                if t != "zero" {
                    if takes[ti - 1] == "1" { format(main, n, "::", t, "(p, s); "); } else { format(main, n, "::", t, "(); "); }
                    format(main, n, "::gw_flush(p, s); ");
                }
                // A store has no render: the output keeps the shape of a component's, with nothing after the JSON.
                format(main, "out.append(\"== ", n, " ", t, "\\n\"); ", n, "::gw_json(out, p, s); out.append(\"\\n\\n== end\\n\"); }\n");
            }
            var link: u8[>..] = [];
            format(link, parity, "/", n, ".goose");
            var target: u8[>..] = [];
            format(target, "../", n, ".goose");
            c_symlink(target, link);
        }
        for oi in component_order() {
            let n = component_names[oi];
            let path = component_paths[oi];
            var src: u8[>..] = [];
            if !read(path, src) { return false; }
            var g: u8[>..] = [];
            var j: u8[>..] = [];
            var e: u8[>..] = [];
            var w: u8[>..] = [];
            component::compile(n, path, src, compact, g, j, e, w);
            p.clear();
            format(p, dir, "/", n, ".js");
            write(p, j);
            if mode == 1 { continue; }
            if mjs_components.len > 0 { mjs_components.push(','); }
            format(mjs_components, "\"", n, "\"");
            let tests = component::test_names();
            let test_takes = component::test_args();
            let takes = split(test_takes, '\n');
            let reactive = component::is_reactive();
            for t, ti in concat(split("zero\n", '\n')[..1], split(tests, '\n')) {
                if t.len == 0 { continue; }
                cases += 1;
                if reactive {
                    // Props are zero here; a test that neither reads nor writes takes no arguments.
                    format(main, "    { var p = ", n, "::Props { .. }; var s = ", n, "::gw_init(p); ");
                    if t != "zero" {
                        if takes[ti - 1] == "1" { format(main, n, "::", t, "(p, s); "); } else { format(main, n, "::", t, "(); "); }
                        format(main, n, "::gw_flush(p, s); ");
                    }
                    format(main, "out.append(\"== ", n, " ", t, "\\n\"); ", n, "::gw_json(out, p, s); out.push('\\n'); ",
                           n, "::render(out, p, s); out.append(\"\\n== end\\n\"); }\n");
                    continue;
                }
                format(main, "    { var s = ", n, "::State { .. }; ");
                if t != "zero" { format(main, n, "::", t, "(s); "); }
                format(main, "out.append(\"== ", n, " ", t, "\\n\"); ", n, "::gw_json(out, s); out.push('\\n'); ",
                       n, "::render(out, s); out.append(\"\\n== end\\n\"); }\n");
            }
            var link: u8[>..] = [];
            format(link, parity, "/", n, ".goose");
            var target: u8[>..] = [];
            format(target, "../", n, ".goose");
            c_symlink(target, link);
        }
    }
    main.append("    write_stdout(out);\n}\n");
    var parity_main: u8[>..] = [];
    format(parity_main, parity, "/main.goose");
    write(parity_main, main);
    var cwd: u8[>..] = [];
    c_cwd(cwd);
    var cmd: u8[>..] = [];
    goose_cmd(cmd);
    cmd.append(" build --color never -o ");
    var bin: u8[>..] = [];
    format(bin, cwd, "/", parity, "/components_test");
    shq(cmd, bin);
    cmd.push(' ');
    var mp: u8[>..] = [];
    format(mp, cwd, "/", parity_main);
    shq(cmd, mp);
    var out: u8[>..] = [];
    if c_run(cmd, out) != 0 {
        var fixed: u8[>..] = [];
        fixed.append(out);
        for n in store_names { to_test_dir(fixed, parity, n); }
        for n in component_names { to_test_dir(fixed, parity, n); }
        write_stderr(rewrite_errors(fixed, cwd));
        write_stderr("gweb test: the parity program did not build\n");
        return false;
    }
    out.clear();
    cmd.clear();
    shq(cmd, bin);
    if c_run(cmd, out) != 0 {
        write_stderr(out);
        write_stderr("\ngweb test: the Goose side of a test stopped (an abort, such as a full u8[..N])\n");
        return false;
    }
    var goose_out: u8[>..] = [];
    format(goose_out, parity, "/goose.out");
    write(goose_out, out);
    var mjs: u8[>..] = [];
    format(mjs, "const COMPONENTS = [", mjs_components, "];\n");
    mjs.append(RUN_MJS);
    var run_mjs: u8[>..] = [];
    format(run_mjs, parity, "/run.mjs");
    write(run_mjs, mjs);
    out.clear();
    var node_cmd: u8[>..] = [];
    node_cmd.append("node ");
    shq(node_cmd, run_mjs);
    let status = c_run(node_cmd, out);
    write_stdout(out);
    return status == 0;
}

// Component modules under test import this as ./gwi.js.
let GWI_SHIM = """
export * from "./gwi.real.js";
import { component as register } from "./gwi.real.js";
export function component(name, def) { globalThis.__gw[name] = def; register(name, def); }

""";

let RUN_MJS = """
// Generated by gweb test: runs each case in JavaScript and compares it with goose.out.
import fs from "node:fs";
globalThis.document = { addEventListener() {}, querySelector() { return null; } };
const text = fs.readFileSync(new URL("./goose.out", import.meta.url), "utf8");
const cases = [];
for (const part of text.split("\n== end\n")) {
  const m = /^== (\S+) (\S+)\n([^\n]*)\n/.exec(part);
  if (m) cases.push({ component: m[1], test: m[2], json: m[3], render: part.slice(m[0].length) });
}
function same(a, b) {
  if (Array.isArray(a) || Array.isArray(b)) {
    return Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((x, i) => same(x, b[i]));
  }
  if (a && b && typeof a === "object" && typeof b === "object") {
    const ka = Object.keys(a), kb = Object.keys(b);
    return ka.length === kb.length && ka.every((k) => Object.hasOwn(b, k) && same(a[k], b[k]));
  }
  return a === b;
}
function firstDiff(a, b) {
  const la = a.split("\n"), lb = b.split("\n");
  for (let i = 0; i < Math.max(la.length, lb.length); i++) {
    if (la[i] !== lb[i]) return { line: i + 1, goose: la[i], js: lb[i] };
  }
  return null;
}
const STUB = { m() {}, f() {}, e() {} };
let failed = 0, run = 0;
for (const mode of ["pretty", "compact"]) {
  globalThis.__gw = {};
  for (const name of COMPONENTS) await import(`./js-${mode}/${name}.js`);
  for (const c of cases) {
    run++;
    const def = globalThis.__gw[c.component];
    const label = `${c.component} ${c.test} (${mode})`;
    let s, html;
    try {
      if (def.i) {
        // A reactive component: the state from zero props, the test, then the computeds again (no DOM, no watches).
        s = def.i();
        if (c.test !== "zero") def.t[c.test](s, STUB);
        def.u(s, -1 >>> 1);
        html = def.r ? def.r(s) : "";
      } else {
        s = def.zero();
        if (c.test !== "zero") def.tests[c.test](s);
        html = def.render(s);
      }
    } catch (err) {
      failed++;
      console.log(`FAIL ${label}: the JavaScript threw ${err}`);
      continue;
    }
    const want = JSON.parse(c.json);
    if (!same(want, s)) {
      failed++;
      console.log(`FAIL ${label}: the state differs\n  goose: ${c.json}\n  js:    ${JSON.stringify(s)}`);
      continue;
    }
    if (html !== c.render) {
      failed++;
      const d = firstDiff(c.render, html);
      console.log(`FAIL ${label}: the render differs at line ${d.line}\n  goose: ${JSON.stringify(d.goose)}\n  js:    ${JSON.stringify(d.js)}`);
      continue;
    }
  }
}
console.log(failed === 0 ? `gweb test: ${run} cases pass (${run / 2} per mode, pretty and compact)` : `gweb test: ${failed} of ${run} cases failed`);
process.exit(failed === 0 ? 0 : 1);
""";

// ---------------------------------------------------------------- routes

fn print_routes() {
    scan();
    if errors > 0 { exit(1); }
    var codes: u8[>..] = [];
    for d in dirs {
        if !d.route && !d.page_html { continue; }
        var line: u8[>..] = [];
        var u: u8[>..] = [];
        url_of(u, d.rel);
        if d.route {
            var src: u8[>..] = [];
            app_path(src, d, "route.goose");
            codes.clear();
            read(src, codes);
            var ms: u8[>..] = [];
            for k in 7 { if defines(codes, METHODS[k]) { if ms.len > 0 { ms.push(','); } ms.append(METHODS[k]); } }
            format(line, "  route  ", ms);
            while line.len < 30 { line.push(' '); }
            format(line, u);
            while line.len < 62 { line.push(' '); }
            format(line, src, "\n");
        } else {
            var src: u8[>..] = [];
            app_path(src, d, "page.html");
            var goose: u8[>..] = [];
            app_path(goose, d, "page.goose");
            codes.clear();
            var has_post = false;
            if d.page_goose && read_file(goose, codes) { has_post = defines(codes, "POST"); }
            format(line, "  page   GET", if has_post { ",POST" } else { "" });
            while line.len < 30 { line.push(' '); }
            format(line, u);
            while line.len < 62 { line.push(' '); }
            format(line, src, "\n");
            var html: u8[>..] = [];
            if read_file(src, html) {
                var rest: const u8[:] = html;
                while true {
                    let k = find(rest, "{#fragment ");
                    if k < 0 { break; }
                    let e = find(rest[k..], "}");
                    if e < 0 { break; }
                    var fl: u8[>..] = [];
                    format(fl, "  frag   ", trim(rest[k + 11..k + e]));
                    while fl.len < 30 { fl.push(' '); }
                    format(fl, u);
                    while fl.len < 62 { fl.push(' '); }
                    format(fl, src, "\n");
                    line.append(fl);
                    rest = rest[k + e..];
                }
            }
        }
        write_stdout(line);
    }
    if has_sitemap {
        for u in ["/sitemap.xml", "/robots.txt"] {
            if u == "/robots.txt" && has_static(u) { continue; }
            var line: u8[>..] = [];
            format(line, "  route  GET,HEAD");
            while line.len < 30 { line.push(' '); }
            format(line, u);
            while line.len < 62 { line.push(' '); }
            format(line, "app/sitemap.goose\n");
            write_stdout(line);
        }
    }
    for s in statics {
        for hashed in [false, true] {
            var line: u8[>..] = [];
            format(line, "  static GET");
            while line.len < 30 { line.push(' '); }
            if hashed { format(line, s.hashed); } else { format(line, s.url); }
            while line.len < 62 { line.push(' '); }
            format(line, s.file, "\n");
            write_stdout(line);
        }
    }
}

// ---------------------------------------------------------------- start and dev

fn server_cmd(extra: u8[:][:], dev: bool) -> u8[>..] {
    var cmd: u8[>..] = [];
    cmd.append("./.gooseweb/server");
    if dev {
        var has_workers = false;
        var has_port = false;
        for a in extra {
            if a == "--workers" { has_workers = true; }
            if a == "--port" { has_port = true; }
        }
        if !has_workers { cmd.append(" --workers 2"); }
        // gweb dev's default port; gweb start and the server keep 3000.
        if !has_port { cmd.append(" --port 60053"); }
        cmd.append(" --log");
        // Restarts on every edit; a long drain would only slow them.
        var has_drain = false;
        for a in extra { if a == "--drain-ms" { has_drain = true; } }
        if !has_drain { cmd.append(" --drain-ms 200"); }
        // A fresh build id per spawn: open pages poll it and reload when it changes.
        format(cmd, " --dev-id ", (time() * 1000.0) as i64);
    }
    // gweb's own flags stay out of the server's command line.
    var skip = false;
    for a in extra {
        if skip { skip = false; continue; }
        if a == "--strict" || a == "--no-minify" { continue; }
        if a == "--diagnostics" { skip = true; continue; }
        cmd.push(' ');
        shq(cmd, a);
    }
    return cmd;
}

fn stamp() -> i64 {
    var count = 0;
    var newest = 0;
    for dir in ["app", "lib", "public", "components", "locales", "stores"] { newest = max(newest, c_tree_stamp(dir, count)); }
    // Path packages are edited beside the project; a git package is a cached tag and never changes.
    for pk in pkgs {
        if pk.git { continue; }
        for sub in ["app", "lib", "public", "components", "stores"] {
            var dir: u8[>..] = [];
            format(dir, pk.dir, "/", sub);
            newest = max(newest, c_tree_stamp(dir, count));
        }
    }
    return newest * 31 + count;
}

// The dev server serves this text in /__gweb/id; open pages show it.
// After each of the first 5 `path:line:` lines whose file exists (relative path), 2 lines before, the line
// marked `>`, and 2 after, each with its number (DESIGN-ADDENDUM-14, D13). Other text passes through.
fn excerpts(text: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    let lines = split(text, '\n');
    var shown = 0;
    for line, li in lines {
        out.append(line);
        let last = li + 1 == lines.len;
        if !last { out.push('\n'); }
        if shown >= 5 || line.len == 0 || line[0] == '/' { continue; }
        let c = find(line, ":");
        if c <= 0 { continue; }
        var e = c + 1;
        while e < line.len && line[e] >= '0' && line[e] <= '9' { e += 1; }
        if e == c + 1 || e >= line.len || line[e] != ':' { continue; }
        let num, nok = parse_int(line[c + 1..e]);
        if !nok || num < 1 { continue; }
        var src: u8[>..] = [];
        if !read_file(line[..c], src) { continue; }
        let sl = split(src, '\n');
        if num > sl.len { continue; }
        shown += 1;
        if last { out.push('\n'); }
        var k = max(num - 2, 1);
        while k <= min(num + 2, sl.len) {
            var n: u8[>..] = [];
            format(n, k);
            out.push(if k == num { '>' } else { ' ' });
            var fill = 4 - n.len;
            while fill > 0 { out.push(' '); fill -= 1; }
            format(out, n, " | ", sl[k - 1], "\n");
            k += 1;
        }
    }
    return out;
}

fn write_dev_errors(text: const u8[:]) {
    make_dir(".gooseweb.dev");
    write_file(".gooseweb.dev/errors.txt", text);
}

fn write_dev_warnings(text: const u8[:]) {
    make_dir(".gooseweb.dev");
    write_file(".gooseweb.dev/warnings.txt", text);
}

fn dev(extra: u8[:][:]) {
    // Hidden, for tests: one build, errors.txt written, exit 0 or 1; no server and no watching.
    for a in extra {
        if a == "--once" {
            write_dev_errors("");
            if build(false, true) { exit(0); }
            write_dev_errors(excerpts(last_errors));
            exit(1);
        }
    }
    var pid: i64 = -1;
    var last = stamp();
    write_dev_errors("");
    write_dev_warnings("");
    let first_ok = build(false, true);
    write_dev_warnings(last_warnings);
    if first_ok {
        pid = c_spawn(server_cmd(extra, true));
    } else {
        write_dev_errors(excerpts(last_errors));
        write_stderr("gweb dev: fix the errors above; watching app/, lib/, public/, components/ and stores/\n");
    }
    if pkgs.len > 0 { last = stamp(); }     // the package folders were not known before the first build
    loop {
        sleep_ms(250);
        if pid > 0 && c_wait(pid, 0) != -2 {
            write_stderr("gweb dev: the server exited; it starts again on the next change\n");
            pid = -1;
        }
        let now = stamp();
        if now == last { continue; }
        sleep_ms(50);          // let an editor finish writing
        last = stamp();
        write_stdout("gweb dev: change seen, rebuilding\n");
        let built = build(false, true);
        write_dev_warnings(last_warnings);
        if !built {
            write_dev_errors(excerpts(last_errors));
            write_stderr("gweb dev: build failed; the old server keeps running\n");
            continue;
        }
        write_dev_errors("");
        if pid > 0 { c_kill(pid, 15); c_wait(pid, 1); }
        pid = c_spawn(server_cmd(extra, true));
    }
}

// ---------------------------------------------------------------- new

let DOCKERFILE = embed_file("../deploy/Dockerfile");
let DOCKERIGNORE = embed_file("../deploy/dockerignore");

fn scaffold(dir: const u8[:]) {
    if is_dir(dir) {
        var probe: u8[>..] = [];
        list_dir(dir, probe);
        if probe.len > 0 { err(dir, 0, "the folder exists and is not empty"); exit(1); }
    }
    let files = [
        ["app/layout.html", """
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{ctx.title}</title>
<link rel="stylesheet" href="/site.css">
</head>
<body>
<nav><a href="/">Home</a> <a href="/hello/goose">Hello</a> <a href="/api/time">API</a></nav>
<main>
@slot()
</main>
</body>
</html>

"""],
        ["app/page.html", """
<h1>gweb</h1>
<p>Edit <code>app/page.html</code>. Worker {ctx.worker} rendered this page.</p>

"""],
        ["app/hello/[name]/page.goose", """
import std;
import net.http;
import gweb;

struct Props { name: const u8[:], shout: bool }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    let name = gweb::param(ctx, "name");
    if name == "nobody" { gweb::not_found(ctx); return Props { .. }; }
    ctx.title.append("Hello");
    let s, has = http::query_param(req, "shout");
    return Props { name: name, shout: has };
}

"""],
        ["app/hello/[name]/page.html", """
<h1>Hello, {props.name}{#if props.shout}!!!{#else}.{/if}</h1>
<ul>
{#for i in 3}
  <li>line {i + 1}</li>
{/for}
</ul>

"""],
        ["app/api/time/route.goose", """
import std;
import net.http;
import gweb;

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    gweb::json(res, http::Status.Ok);
    format(res.body, "{\"unix\":", time() as i64, ",\"worker\":", ctx.worker, "}");
}

"""],
        ["app/not-found.html", """
<h1>Not found</h1>
<p>No page at {req.path}.</p>

"""],
        [".gitignore", ".gooseweb/\n.gooseweb.dev/\n.gooseweb.test/\n.gooseweb.lsp/\n.gooseweb.check/\n.env*.local\n"],
        ["Dockerfile", DOCKERFILE],
        [".dockerignore", DOCKERIGNORE],
        ["public/site.css", """
body { font-family: system-ui, sans-serif; max-width: 40rem; margin: 2rem auto; }
nav a { margin-right: 1rem; }

"""],
    ];
    for f in files {
        var path: u8[>..] = [];
        format(path, dir, "/", f[0]);
        make_dir(dir);
        var at = dir.len + 1;
        loop {
            let k = find(path[at..], "/");
            if k < 0 { break; }
            make_dir(path[..at + k]);
            at = at + k + 1;
        }
        write(path, f[1]);
    }
    var msg: u8[>..] = [];
    format(msg, "gweb: made ", dir, "\n  cd ", dir, " && gweb dev\n");
    write_stdout(msg);
}

// ---------------------------------------------------------------- main

fn has_flag(rest: u8[:][:], flag: const u8[:]) -> bool {
    for a in rest { if a == flag { return true; } }
    return false;
}

fn usage() {
    write_stderr("""
usage: gweb [-C dir] <command>
  new <dir>         make a starter project
  gen               write .gooseweb/ only
  build [--debug]   gen, then goose build to .gooseweb/server
                    gen, build, start and test also take --strict (warnings fail the run)
                    and --diagnostics json (stderr as JSON Lines)
  start [flags]     build, then run the server (flags go to it: --port N --workers N --log ...)
  --no-minify       with gen, build or start: serve public/**/*.css as written
  export [-o DIR]   build, then write the site as static files to DIR (default out/)
  dev [flags]       build, run on port 60053 (unless --port), and rebuild on every change under app/, lib/, public/, components/, locales/, stores/
  routes            print the route table
  version           print the version and the package sources a build declares
  check             generate into .gooseweb.check/ and run goose check; errors name .gshtml and page.html lines
  lsp               run the language server (needs node)
  test              component test_* functions as Goose and as JavaScript (they must match), then tests/*.goose route tests

""");
    exit(2);
}

fn main() {
    let a = args();
    c_cwd(start_cwd);
    var i = 1;
    if a.len > 2 && a[1] == "-C" {
        if c_chdir(a[2]) == 0 { err(a[2], 0, "cannot change to this folder"); exit(1); }
        i = 3;
    }
    if i >= a.len { usage(); }
    let cmd = a[i];
    let rest = a[i + 1..];
    if cmd == "version" { print_version(); return; }
    check_version();
    if cmd == "new" { if rest.len != 1 { usage(); } scaffold(rest[0]); return; }
    if cmd == "test-css" { if !test_css() { exit(1); } return; }
    minify = !has_flag(rest, "--no-minify");
    if cmd == "gen" {
        parse_flags(rest, false);
        if !gen(false, BUILD_DIR) || component_errors > 0 { exit(1); }
        write_stdout("gweb: wrote .gooseweb/\n");
        if !strict_ok() { exit(1); }
        return;
    }
    if cmd == "lsp-gen" { lsp_gen_cmd(rest); return; }
    if cmd == "check" { parse_flags(rest, false); if !check_cmd() || !strict_ok() { exit(1); } return; }
    if cmd == "lsp" { lsp_cmd(a[0]); return; }
    if cmd == "test" { parse_flags(rest, false); if !test_cmd() || !strict_ok() { exit(1); } return; }
    if cmd == "build" { parse_flags(rest, true); if !build(debug_flag, false) || !strict_ok() { exit(1); } return; }
    if cmd == "routes" { print_routes(); return; }
    if cmd == "start" {
        parse_flags(rest, false);
        if !build(false, false) || !strict_ok() { exit(1); }
        c_exec(server_cmd(rest, false));
        write_stderr("gweb: could not start .gooseweb/server\n");
        exit(1);
    }
    if cmd == "export" {
        var dir: u8[>..] = [];
        dir.append("out");
        var k = 0;
        while k < rest.len {
            if rest[k] == "-o" && k + 1 < rest.len && rest[k + 1].len > 0 { dir.clear(); dir.append(rest[k + 1]); k += 2; }
            else if rest[k] == "--no-minify" { k += 1; }
            else { usage(); }
        }
        if !build(false, false) { exit(1); }
        var cmd: u8[>..] = [];
        cmd.append("./.gooseweb/server --export ");
        shq(cmd, dir);
        c_exec(cmd);
        write_stderr("gweb: could not start .gooseweb/server\n");
        exit(1);
    }
    if cmd == "dev" { minify = false; dev(rest); return; }
    usage();
}
