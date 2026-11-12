// gweb: the goose-web command line. See ../DESIGN.md section 9.
//
//   gweb [-C dir] new <dir>
//   gweb [-C dir] gen | build [--debug] | routes
//   gweb [-C dir] start [server flags...]
//   gweb [-C dir] dev [server flags...]
//   gweb [-C dir] test
//
// It scans app/, lib/ and public/ and writes a program to .gooseweb/:
// copies of the app files with a namespace on line 1, one Goose file per
// template (one Goose line per HTML line), main.goose with the dispatcher,
// and map.txt. Then it runs `goose build` and maps error paths back.
// Components (components/Name.gshtml, DESIGN-ADDENDUM-3) go through component.goose.

import std;
import os;
import component;

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

// ---------------------------------------------------------------- model

// One directory under app/. rel is "" for app/ itself, else "api/todos/[id]".
struct Dir {
    rel: u8[..512],
    route: bool, page_html: bool, page_goose: bool, layout: bool, middleware: bool,
    methods: i64,          // bit i set: METHODS[i] is defined in route.goose
    has_load: bool, has_before: bool, has_after: bool,
    route_ns: u8[..200], page_ns: u8[..200], layout_ns: u8[..32], mw_ns: u8[..32]
}

// One file under public/.
struct Static { url: u8[..512], file: u8[..512], ctype: u8[..64], etag: u8[..24] }

let METHODS = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"];
let VARIANTS = ["Get", "Head", "Post", "Put", "Patch", "Delete", "Options"];

var dirs: Dir[>..<];
var statics: Static[>..<];
var errors = 0;
var has_state = false;
var has_state_init = false;
var has_not_found = false;
var uses_sqlite = false;
var map_text: u8[>..];
var component_names: u8[..64][>..<];   // components/Name.gshtml, sorted
var component_lines: i64[>..<];        // each component's source line count
var component_errors = 0;              // translator errors of this gen; the build still runs goose
var last_errors: u8[>..];      // what this build printed as errors, for the dev overlay (max 16 KB)

fn note_errors(text: const u8[:]) {
    let room = 16384 - last_errors.len;
    if room > 0 { last_errors.append(text[..min(text.len, room)]); }
}

// ---------------------------------------------------------------- small helpers

fn err(path: const u8[:], line: i64, msg: const u8[:]) {
    var s: u8[>..] = [];
    if line > 0 { format(s, path, ":", line, ": error: ", msg, "\n"); } else { format(s, path, ": error: ", msg, "\n"); }
    write_stderr(s);
    note_errors(s);
    errors += 1;
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

// Appends s as a single-quoted shell word.
fn shq(out: u8[>..]&, s: const u8[:]) {
    out.push('\'');
    for c in s { if c == '\'' { out.append("'\\''"); } else { out.push(c); } }
    out.push('\'');
}

// Appends s as the inside of a Goose string literal.
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

// Lines starting (after indentation) with `fn <name>(`.
fn defines(src: const u8[:], name: const u8[:]) -> bool {
    var pat: u8[>..] = [];
    format(pat, "fn ", name, "(");
    for line in split(src, '\n') { if starts_with(trim_start(line), pat) { return true; } }
    return false;
}

fn read(path: const u8[:], out: u8[>..]&) -> bool {
    if !read_file(path, out) { err(path, 0, "cannot read"); return false; }
    return true;
}

fn write(path: const u8[:], data: const u8[:]) {
    if !write_file(path, data) { err(path, 0, "cannot write"); }
}

// rel_a is rel_b or one of its ancestors.
fn is_ancestor(a: const u8[:], b: const u8[:]) -> bool {
    if a.len == 0 || a == b { return true; }
    return b.len > a.len && starts_with(b, a) && b[a.len] == '/';
}

fn app_path(out: u8[>..]&, rel: const u8[:], file: const u8[:]) {
    out.append("app/");
    if rel.len > 0 { out.append(rel); out.push('/'); }
    out.append(file);
}

fn url_of(out: u8[>..]&, rel: const u8[:]) { out.push('/'); out.append(rel); }

// ---------------------------------------------------------------- scan

fn scan_dir(rel: const u8[:], todo: u8[..512][>..]&) {
    var path: u8[>..] = [];
    path.append("app");
    if rel.len > 0 { path.push('/'); path.append(rel); }
    var names: u8[>..] = [];
    if !list_dir(path, names) { return; }
    var d = Dir { rel: "", route: false, page_html: false, page_goose: false, layout: false, middleware: false,
                  methods: 0, has_load: false, has_before: false, has_after: false,
                  route_ns: "", page_ns: "", layout_ns: "", mw_ns: "" };
    if rel.len >= 512 { err(path, 0, "path too long"); return; }
    d.rel.append(rel);
    var subdirs: u8[>..] = [];
    for name in split(names, '\n') {
        if name.len == 0 { continue; }
        var full: u8[>..] = [];
        format(full, path, "/", name);
        if is_dir(full) {
            if name[0] == '_' || name[0] == '.' { continue; }
            if name[0] == '[' {
                if name.len < 3 || name[name.len - 1] != ']' || !is_ident(name[1..name.len - 1]) {
                    err(full, 0, "a dynamic segment folder is [name], where name is an identifier");
                    continue;
                }
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
        else if name == "not-found.html" {
            if rel.len == 0 { has_not_found = true; } else { err(full, 0, "not-found.html belongs in app/ only"); }
        }
        else if name == "state.goose" {
            if rel.len == 0 { has_state = true; } else { err(full, 0, "state.goose belongs in app/ only"); }
        }
    }
    if d.route && d.page_html { err(path, 0, "a folder has route.goose or page.html, not both"); }
    if d.page_goose && !d.page_html { err(path, 0, "page.goose needs a page.html beside it"); }
    let i = dirs.len;
    var n: u8[>..] = [];
    var sl: u8[>..] = [];
    slug(sl, rel);
    if d.route { n.clear(); format(n, "r", i); if sl.len > 0 { format(n, "_", sl); } d.route_ns.append(n[..min(n.len, 200)]); }
    if d.page_html { n.clear(); format(n, "p", i); if sl.len > 0 { format(n, "_", sl); } d.page_ns.append(n[..min(n.len, 200)]); }
    if d.layout { n.clear(); format(n, "l", i); d.layout_ns.append(n); }
    if d.middleware { n.clear(); format(n, "m", i); d.mw_ns.append(n); }
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

// Every folder under app/, parents before children.
fn scan_app() {
    var todo: u8[..512][>..] = [];
    todo.push("");
    while todo.len > 0 {
        let rel: u8[..512] = todo[todo.len - 1];
        todo.pop();
        scan_dir(rel, todo);
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

// The quoted FNV-1a hash of data, as an ETag.
fn etag_of(data: const u8[:]) -> u8[..24] {
    var h: u64 = 14695981039346656037;
    for c in data { h = (h ^ c) * 1099511628211; }
    var t: u8[..24] = "\"";
    let hex = "0123456789abcdef";
    for k in 16 { t.push(hex[(h >> ((15 - k) * 4) as u64) & 15]); }
    t.push('"');
    return t;
}

fn scan_public_dir(rel: const u8[:], todo: u8[..512][>..]&) {
    var path: u8[>..] = [];
    path.append("public");
    if rel.len > 0 { path.push('/'); path.append(rel); }
    var names: u8[>..] = [];
    if !list_dir(path, names) { return; }
    for name in split(names, '\n') {
        if name.len == 0 || name[0] == '.' { continue; }
        var r: u8[>..] = [];
        if rel.len > 0 { format(r, rel, "/"); }
        r.append(name);
        var full: u8[>..] = [];
        format(full, "public/", r);
        if is_dir(full) { if r.len < 512 { var t: u8[..512] = ""; t.append(r); todo.push(t); } continue; }
        if r.len >= 500 { err(full, 0, "path too long"); continue; }
        var data: u8[>..] = [];
        if !read(full, data) { continue; }
        var s = Static { url: "/", file: "", ctype: "", etag: "" };
        s.url.append(r);
        s.file.append(full);
        s.ctype.append(content_type(name));
        s.etag = etag_of(data);
        statics.push(s);
    }
}

fn scan_public() {
    var todo: u8[..512][>..] = [];
    todo.push("");
    while todo.len > 0 {
        let rel: u8[..512] = todo[todo.len - 1];
        todo.pop();
        scan_public_dir(rel, todo);
    }
}

// components/*.gshtml: the names, checked (DESIGN-ADDENDUM-3, E1).
fn scan_components() {
    component_names.clear();
    if is_dir("public/_gw") { err("public/_gw", 0, "/_gw/ is goose-web's component folder; rename this folder"); }
    var names: u8[>..] = [];
    if !list_dir("components", names) { return; }
    var found: u8[..64][>..<] = [];
    for f in split(names, '\n') {
        if f.len == 0 || f[0] == '.' || !ends_with(f, ".gshtml") { continue; }
        let n = f[..f.len - 7];
        var ok = n.len > 0 && n.len <= 64 && n[0] >= 'A' && n[0] <= 'Z';
        for c in n { if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) { ok = false; } }
        var p: u8[>..] = [];
        format(p, "components/", f);
        if !ok { err(p, 0, "a component's name is [A-Z][A-Za-z0-9]*, as in components/TodoBox.gshtml"); continue; }
        var t: u8[..64] = "";
        t.append(n);
        found.push(t);
    }
    sort(found) { a, b => compare(a, b) < 0 };
    for t in found { component_names.push(t); }
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
    has_not_found = false;
    if !is_dir("app") { err("app", 0, "no app/ folder here; run gweb in a project, or gweb new <dir>"); return; }
    scan_app();
    scan_public();
    scan_components();
    // A public file may not shadow a route at the same literal URL.
    for d in dirs {
        if !d.route && !d.page_html { continue; }
        var u: u8[>..] = [];
        url_of(u, d.rel);
        for s in statics { if s.url == u { err(s.file, 0, "this file has the same URL as a route"); } }
    }
}

// ---------------------------------------------------------------- copies

// Copies an app file to .gooseweb/<ns>.goose with `namespace ns; ` on line 1.
fn copy_prefixed(src: const u8[:], ns: const u8[:], code: u8[>..]&) -> bool {
    if !read(src, code) { return false; }
    for line, i in split(code, '\n') {
        if starts_with(trim_start(line), "namespace ") {
            err(src, i + 1, "app files get their namespace from gweb; remove this line");
            return false;
        }
    }
    if imports_sqlite(code) { uses_sqlite = true; }
    var out: u8[>..] = [];
    format(out, "namespace ", ns, "; ", code);
    var dst: u8[>..] = [];
    format(dst, ".gooseweb/", ns, ".goose");
    write(dst, out);
    format(map_text, ns, ".goose\t", src, "\n");
    return true;
}

// A Goose file with an `import sqlite;` line.
fn imports_sqlite(code: const u8[:]) -> bool {
    for line in split(code, '\n') { if find(line, "import sqlite;") >= 0 && starts_with(trim(line), "import") { return true; } }
    return false;
}

// Looks for `import sqlite;` in every .goose file under lib/.
fn scan_lib_for_sqlite() {
    var todo: u8[..512][>..] = [];
    todo.push("lib");
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
                if read_file(full, code) && imports_sqlite(code) { uses_sqlite = true; }
            }
        }
    }
}

// The import lines of a Goose file, joined on one line.
fn imports_of(src: const u8[:], out: u8[>..]&) {
    for line in split(src, '\n') {
        let t = trim(line);
        if starts_with(t, "import ") { out.append(t); out.push(' '); }
    }
}

fn add_default_imports(imports: u8[>..]&) {
    for imp in ["import std;", "import net.http;", "import web;", "import web.template;"] {
        if find(imports, imp) < 0 { imports.append(imp); imports.push(' '); }
    }
    for n in component_names {
        var imp: u8[>..] = [];
        format(imp, "import ", n, ";");
        if find(imports, imp) < 0 { imports.append(imp); imports.push(' '); }
    }
}

// ---------------------------------------------------------------- templates

// Compiles a template. header ends with `{ `; every HTML line becomes one
// Goose line, so errors keep their line numbers. False on a template error.
fn compile_template(path: const u8[:], src: const u8[:], header: const u8[:], layout: bool, out: u8[>..]&) -> bool {
    let before = errors;
    out.append(header);
    var stack: u8[>..] = [];      // 'i' for if, 'f' for for
    var stack_lines: i64[>..] = [];
    let lines = split(src, '\n');
    for line, li in lines {
        let ln = li + 1;
        let last = li == lines.len - 1;
        var text: u8[>..] = [];
        var pos = 0;
        while pos < line.len {
            let k = find(line[pos..], "{{");
            if k < 0 { text.append(line[pos..]); break; }
            text.append(line[pos..pos + k]);
            if text.len > 0 { out.append("out.append(\""); lit(out, text); out.append("\"); "); text.clear(); }
            let at = pos + k;
            let rest = line[at..];
            if starts_with(rest, "{{--") {
                let e = find(rest, "--}}");
                if e < 0 { err(path, ln, "{{-- needs --}} on the same line"); return false; }
                pos = at + e + 4;
                continue;
            }
            if starts_with(rest, "{{{") {
                let e = find(rest, "}}}");
                if e < 0 { err(path, ln, "{{{ needs }}} on the same line"); return false; }
                let expr = trim(rest[3..e]);
                if expr.len == 0 { err(path, ln, "empty {{{ }}}"); }
                format(out, "web::raw(out, ", expr, "); ");
                pos = at + e + 3;
                continue;
            }
            let e = find(rest, "}}");
            if e < 0 { err(path, ln, "{{ needs }} on the same line"); return false; }
            let inner = trim(rest[2..e]);
            pos = at + e + 2;
            if starts_with(inner, "#if ") {
                format(out, "if ", trim(inner[4..]), " { ");
                stack.push('i'); stack_lines.push(ln);
            } else if starts_with(inner, "#else if ") {
                if stack.len == 0 || stack[stack.len - 1] != 'i' { err(path, ln, "{{#else if}} outside {{#if}}"); }
                format(out, "} else if ", trim(inner[9..]), " { ");
            } else if inner == "#else" {
                if stack.len == 0 || stack[stack.len - 1] != 'i' { err(path, ln, "{{#else}} outside {{#if}}"); }
                out.append("} else { ");
            } else if starts_with(inner, "#for ") {
                let body = trim(inner[5..]);
                if find(body, " in ") < 0 { err(path, ln, "{{#for x in e}} or {{#for x, i in e}}"); }
                format(out, "for ", body, " { ");
                stack.push('f'); stack_lines.push(ln);
            } else if starts_with(inner, "#let ") {
                format(out, "let ", trim(inner[5..]), "; ");
            } else if inner == "/if" || inner == "/for" {
                let want: u8 = if inner == "/if" { 'i' } else { 'f' };
                if stack.len == 0 || stack[stack.len - 1] != want {
                    var m: u8[>..] = [];
                    format(m, "{{", inner, "}} does not close an open {{#", inner[1..], "}}");
                    err(path, ln, m);
                } else { stack.pop(); stack_lines.pop(); }
                out.append("} ");
            } else if starts_with(inner, ">") {
                let call = trim(inner[1..]);
                let open = find(call, "(");
                if open <= 0 || call[call.len - 1] != ')' { err(path, ln, "{{> f(args)}} calls a function"); }
                else {
                    let args = trim(call[open + 1..call.len - 1]);
                    if args.len == 0 { format(out, call[..open], "(out); "); }
                    else { format(out, call[..open], "(out, ", args, "); "); }
                }
            } else if inner == "slot" {
                if !layout { err(path, ln, "{{slot}} is for layout.html only"); }
                out.append("F(); ");
            } else if starts_with(inner, "component ") {
                // {{component Name(expr)}}: the component, rendered with state expr.
                let call = trim(inner["component ".len..]);
                let open = find(call, "(");
                if open <= 0 || call[call.len - 1] != ')' { err(path, ln, "{{component Name(expr)}} takes a component name and its state"); }
                else {
                    let nm = trim(call[..open]);
                    if !has_component(nm) {
                        var m: u8[>..] = [];
                        format(m, "no component named ", nm, " (there is no components/", nm, ".gshtml)");
                        err(path, ln, m);
                    } else { format(out, nm, "::component(out, ", trim(call[open + 1..call.len - 1]), "); "); }
                }
            } else if starts_with(inner, "#") || starts_with(inner, "/") {
                var m: u8[>..] = [];
                format(m, "unknown tag {{", inner, "}}");
                err(path, ln, m);
            } else {
                if inner.len == 0 { err(path, ln, "empty {{ }}"); }
                format(out, "web::put(out, ", inner, "); ");
            }
        }
        if !last { text.push('\n'); }
        if text.len > 0 { out.append("out.append(\""); lit(out, text); out.append("\"); "); }
        if last { out.append("}"); }
        out.push('\n');
    }
    if stack.len > 0 {
        let what = if stack[stack.len - 1] == 'i' { "{{#if}} is never closed with {{/if}}" } else { "{{#for}} is never closed with {{/for}}" };
        err(path, stack_lines[stack_lines.len - 1], what);
    }
    if layout && find(src, "{{slot}}") < 0 { err(path, 0, "a layout needs {{slot}} where the page goes"); }
    return errors == before;
}

fn gen_template(src_path: const u8[:], ns: const u8[:], file_base: const u8[:], signature: const u8[:],
                imports: const u8[:], layout: bool) {
    var src: u8[>..] = [];
    if !read(src_path, src) { return; }
    var header: u8[>..] = [];
    format(header, "namespace ", ns, "; ", imports, signature, " { ");
    var out: u8[>..] = [];
    if !compile_template(src_path, src, header, layout, out) { return; }
    var dst: u8[>..] = [];
    format(dst, ".gooseweb/", file_base, ".goose");
    write(dst, out);
    format(map_text, file_base, ".goose\t", src_path, "\n");
}

// ---------------------------------------------------------------- main.goose

let SIG = "(req: const http::Request&, ctx: web::Ctx&, res: http::Response&)";

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

fn middleware_before(m: u8[>..]&, d: const Dir&) {
    for o in dirs {
        if o.middleware && o.has_before && is_ancestor(o.rel, d.rel) {
            format(m, "    if !", o.mw_ns, "::before(req, ctx, res) { return; }\n");
        }
    }
}

fn middleware_after(m: u8[>..]&, d: const Dir&) {
    var k = dirs.len;
    while k > 0 {
        k -= 1;
        let o = dirs[k];
        if o.middleware && o.has_after && is_ancestor(o.rel, d.rel) {
            format(m, "    ", o.mw_ns, "::after(req, ctx, res);\n");
        }
    }
}

fn gen_route_fn(m: u8[>..]&, d: const Dir&, i: i64) {
    var allow: u8[>..] = [];
    allow_list(d, allow);
    format(m, "fn route_", i, SIG, " {   // app/", d.rel, if d.rel.len > 0 { "/" } else { "" }, "route.goose\n");
    middleware_before(m, d);
    m.append("    match req.method {\n");
    for k in 7 {
        let has = (d.methods >> k) & 1 == 1;
        if has { format(m, "        ", VARIANTS[k], " => ", d.route_ns, "::", METHODS[k], "(req, ctx, res),\n"); }
        else if k == 1 && d.methods & 1 == 1 { format(m, "        Head => ", d.route_ns, "::GET(req, ctx, res),\n"); }
        else if k == 6 { format(m, "        Options => web::options(res, \"", allow, "\"),\n"); }
    }
    format(m, "        _ => web::method_not_allowed(res, \"", allow, "\"),\n");
    m.append("    }\n");
    middleware_after(m, d);
    m.append("}\n");
}

fn gen_page_fn(m: u8[>..]&, d: const Dir&, i: i64) {
    format(m, "fn page_", i, SIG, " {   // app/", d.rel, if d.rel.len > 0 { "/" } else { "" }, "page.html\n");
    m.append("    match req.method {\n");
    m.append("        Get, Head => {},\n");
    m.append("        Options => { web::options(res, \"GET, HEAD, OPTIONS\"); return; },\n");
    m.append("        _ => { web::method_not_allowed(res, \"GET, HEAD, OPTIONS\"); return; },\n");
    m.append("    }\n");
    middleware_before(m, d);
    m.append("    web::html(res, http::Status.Ok);\n");
    if d.has_load { format(m, "    let props = ", d.page_ns, "::load(req, ctx);\n"); }
    m.append("    if ctx.outcome == web::Outcome.Continue {\n        ");
    var closes = 0;
    for o in dirs {
        if o.layout && is_ancestor(o.rel, d.rel) { format(m, o.layout_ns, "::render(res.body, req, ctx) { "); closes += 1; }
    }
    format(m, d.page_ns, "::render(res.body, req, ctx", if d.has_load { ", props" } else { "" }, ");");
    for c in closes { m.append(" };"); }
    m.append("\n    }\n");
    middleware_after(m, d);
    m.append("}\n");
}

// Segment-wise order: a literal segment before a dynamic one.
fn route_before(a: const u8[:], b: const u8[:]) -> bool {
    let sa = split(a, '/');
    let sb = split(b, '/');
    for k in min(sa.len, sb.len) {
        let da = sa[k].len > 0 && sa[k][0] == '[';
        let db = sb[k].len > 0 && sb[k][0] == '[';
        if da != db { return !da; }
    }
    return false;
}

fn seg_count(rel: const u8[:]) -> i64 {
    if rel.len == 0 { return 0; }
    var n = 1;
    for c in rel { if c == '/' { n += 1; } }
    return n;
}

fn gen_dispatch(m: u8[>..]&) {
    format(m, "fn dispatch", SIG, " -> i64 {\n");
    m.append("    var seg: const u8[:][16] = [\"\"; 16];\n");
    m.append("    var starts: i64[16] = [0; 16];\n");
    m.append("    var ends: i64[16] = [0; 16];\n");
    m.append("    let n = web::split(req.path, seg, starts, ends);\n");
    m.append("    match n {\n");
    for count in 17 {
        // The routes with this many segments, literal-first.
        var order: i64[>..] = [];
        for d, i in dirs {
            if (d.route || d.page_html) && seg_count(d.rel) == count {
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
        if order.len == 0 { continue; }
        format(m, "        ", count, " => {\n");
        for i in order {
            let d = dirs[i];
            var cond: u8[>..] = [];
            var params: u8[>..] = [];
            if count > 0 {
                for s, k in split(d.rel, '/') {
                    if s[0] == '[' {
                        if params.len > 0 { params.append(" && "); }
                        format(params, "web::set_param(ctx, \"", s[1..s.len - 1], "\", seg[", k, "])");
                    } else {
                        if cond.len > 0 { cond.append(" && "); }
                        cond.append("seg["); format(cond, k); cond.append("] == \""); lit(cond, s); cond.push('"');
                    }
                }
            }
            let call_kind = if d.route { "route_" } else { "page_" };
            var call: u8[>..] = [];
            format(call, call_kind, i, "(req, ctx, res);");
            var body: u8[>..] = [];
            if params.len > 0 { format(body, "if ", params, " { ", call, " } else { web::not_found(ctx); } finish(req, ctx, res); return -1;"); }
            else { format(body, call, " finish(req, ctx, res); return -1;"); }
            var u: u8[>..] = [];
            url_of(u, d.rel);
            if cond.len > 0 { format(m, "            if ", cond, " { ", body, " }   // ", u, "\n"); }
            else { format(m, "            { ", body, " }   // ", u, "\n"); }
        }
        m.append("        },\n");
    }
    m.append("        _ => {},\n");
    m.append("    }\n");
    m.append("    if req.method == http::Method.Get || req.method == http::Method.Head {\n");
    m.append("        let i, hit = static_file(req, res);\n");
    m.append("        if hit { return i; }\n");
    m.append("    }\n");
    m.append("    web::not_found(ctx);\n");
    m.append("    finish(req, ctx, res);\n");
    m.append("    return -1;\n");
    m.append("}\n");
}

fn gen_static(m: u8[>..]&) {
    for s, i in statics {
        format(m, "let S", i, " = embed_file(\"../"); lit(m, s.file); m.append("\");\n");
    }
    m.append("fn static_bytes(i: i64) -> const u8[:] {\n");
    for s, i in statics { format(m, "    if i == ", i, " { return S", i, "; }\n"); }
    m.append("    return \"\";\n}\n");
    m.append("fn static_file(req: const http::Request&, res: http::Response&) -> i64, bool {\n");
    if statics.len > 0 {
        m.append("    let p = req.path;\n    match p.len {\n");
        var lens: i64[>..] = [];
        for s in statics { if !contains(lens, s.url.len) { lens.push(s.url.len); } }
        sort(lens);
        for l in lens {
            format(m, "        ", l, " => {\n");
            for s, i in statics {
                if s.url.len != l { continue; }
                m.append("            if p == \""); lit(m, s.url);
                format(m, "\" { return web::send_static(req, res, ", i, ", \"", s.ctype, "\", \""); lit(m, s.etag);
                m.append("\"), true; }\n");
            }
            m.append("        },\n");
        }
        m.append("        _ => {},\n    }\n");
    }
    m.append("    return -1, false;\n}\n");
}

fn gen_finish(m: u8[>..]&) {
    m.append("fn finish(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {\n");
    m.append("    match ctx.outcome {\n        Continue => {},\n        NotFound => {\n");
    if has_not_found {
        m.append("            ctx.title.clear();\n            res.body.clear();\n            web::html(res, http::Status.NotFound);\n");
        var root_layout: u8[>..] = [];
        for d in dirs { if d.rel.len == 0 && d.layout { root_layout.append(d.layout_ns); } }
        if root_layout.len > 0 { format(m, "            ", root_layout, "::render(res.body, req, ctx) { nf::render(res.body, req, ctx); };\n"); }
        else { m.append("            nf::render(res.body, req, ctx);\n"); }
    } else {
        m.append("            res.body.clear();\n            web::plain_not_found(res);\n");
    }
    m.append("        },\n        Redirect => web::apply_redirect(ctx, res),\n    }\n}\n");
}

fn gen_main(home: const u8[:]) -> u8[>..] {
    var m: u8[>..] = [];
    m.append("// Generated by gweb. Do not edit; it is rewritten on every build.\n");
    m.append("import std;\n");
    m.append("import web from \""); lit(m, home); m.append("\";\n");
    m.append("import net from \""); lit(m, home); m.append("/../goose-net\";\n");
    if uses_sqlite { m.append("import sqlite from \""); lit(m, home); m.append("/../goose-sqlite\";\n"); }
    m.append("import net.http;\nimport web.template;\nimport web.static;\nimport web.owner;\n");
    for d in dirs {
        if d.route { format(m, "import ", d.route_ns, ";\n"); }
        if d.page_html { format(m, "import ", d.page_ns, "_html;\n"); if d.page_goose { format(m, "import ", d.page_ns, ";\n"); } }
        if d.layout { format(m, "import ", d.layout_ns, ";\n"); }
        if d.middleware { format(m, "import ", d.mw_ns, ";\n"); }
    }
    if has_not_found { m.append("import nf;\n"); }
    if has_state {
        m.append("import state;\n");
        m.append("fn state::ask(ctx: const web::Ctx&, msg: state::Msg) -> state::Reply, bool {\n");
        m.append("    return web::owner_call_fd<state::Msg, state::Reply>(ctx.owner_fd, msg);\n}\n");
    }
    m.append("\n");
    gen_static(m);
    m.append("\n");
    for d, i in dirs {
        if d.route { gen_route_fn(m, d, i); }
        if d.page_html { gen_page_fn(m, d, i); }
    }
    m.append("\n");
    gen_finish(m);
    m.append("\n");
    gen_dispatch(m);
    m.append("""
thread_fn worker(slot: i64, server: net::Socket, owner_fd: i32, cfg: web::Config) {
    web::run_worker(slot, server, owner_fd, cfg, dispatch, static_bytes);
}

thread_fn supervisor(slot: i64, server: net::Socket, owner_fd: i32, cfg: web::Config) {
    var why: u8[>..] = [];
    while !thread_wait(thread_spawn_contained(worker, slot, server, owner_fd, cfg), why) {
        print("goose-web: worker ", slot, " stopped: ", why, "; restarting it");
        why.clear();
    }
}

fn main() {
    let cfg = web::config_from_args();
    let server = net::listen(cfg.port, cfg.host, 1024);
    guard server.ok() else { print("goose-web: cannot listen on port ", cfg.port, ": ", net::last_error()); exit(1); }

""");
    if has_state {
        if has_state_init { m.append("    state::init();\n"); }
        m.append("    let chans = web::owner_channels(cfg.workers);\n");
    }
    m.append("    print(\"goose-web: http://localhost:\", cfg.port, \" (\", cfg.workers, \" workers)\");\n");
    m.append("    var ids: i64[>..] = [];\n");
    if has_state { m.append("    for i in cfg.workers { ids.push(thread_spawn(supervisor, i, server, web::worker_end(chans, i), cfg)); }\n"); }
    else { m.append("    for i in cfg.workers { ids.push(thread_spawn(supervisor, i, server, -1, cfg)); }\n"); }
    if has_state { m.append("    web::owner_loop<state::Msg, state::Reply>(chans, state::handle);\n"); }
    m.append("    for id in ids { thread_wait(id); }\n}\n");
    return m;
}

// ---------------------------------------------------------------- gen

fn goose_web_home() -> u8[>..] {
    var h: u8[>..] = [];
    if env("GOOSE_WEB_HOME", h) && h.len > 0 {
        while h.len > 1 && h[h.len - 1] == '/' { h.pop(); }
        return h;
    }
    h.clear();
    resource_dir(h);
    while h.len > 1 && h[h.len - 1] == '/' { h.pop(); }
    return h;
}

// ---------------------------------------------------------------- components

fn push_gw_static(url: const u8[:], file: const u8[:], data: const u8[:]) {
    var s = Static { url: "", file: "", ctype: "text/javascript; charset=utf-8", etag: "" };
    s.url.append(url);
    s.file.append(file);
    s.etag = etag_of(data);
    statics.push(s);
}

// Translates every component to .gooseweb/Name.goose and .gooseweb/_gw/Name.js,
// copies the runtime to .gooseweb/_gw/gwi.js (client/gwi.js in dev,
// client/gwi.min.js otherwise) and adds all of them to the static files.
// Translator errors are printed and counted in component_errors; gen goes on,
// so the Goose compiler reports its errors too.
fn gen_components(dev: bool) {
    component_lines.clear();
    if component_names.len == 0 { return; }
    make_dir(".gooseweb/_gw");
    var rt_path: u8[>..] = [];
    format(rt_path, goose_web_home(), if dev { "/client/gwi.js" } else { "/client/gwi.min.js" });
    var rt: u8[>..] = [];
    if !read(rt_path, rt) { return; }
    write(".gooseweb/_gw/gwi.js", rt);
    push_gw_static("/_gw/gwi.js", ".gooseweb/_gw/gwi.js", rt);
    for n in component_names {
        var path: u8[>..] = [];
        format(path, "components/", n, ".gshtml");
        var src: u8[>..] = [];
        component_lines.push(0);
        if !read(path, src) { continue; }
        var lines = 1;
        for c in src { if c == '\n' { lines += 1; } }
        component_lines[component_lines.len - 1] = lines;
        var g: u8[>..] = [];
        var j: u8[>..] = [];
        var e: u8[>..] = [];
        if !component::compile(n, path, src, !dev, g, j, e) {
            write_stderr(e);
            note_errors(e);
            for c in e { if c == '\n' { component_errors += 1; } }
            if e.len == 0 { component_errors += 1; }
        }
        var dst: u8[>..] = [];
        format(dst, ".gooseweb/", n, ".goose");
        write(dst, g);
        format(map_text, n, ".goose\t", path, "\n");
        dst.clear();
        format(dst, ".gooseweb/_gw/", n, ".js");
        write(dst, j);
        var url: u8[>..] = [];
        format(url, "/_gw/", n, ".js");
        push_gw_static(url, dst, j);
    }
}

// Writes .gooseweb/. False when there were errors. dev picks readable component
// JS and the unminified runtime (DESIGN-ADDENDUM-3, follow-up 1).
fn gen(dev: bool) -> bool {
    scan();
    if errors > 0 { return false; }
    c_remove_tree(".gooseweb");
    make_dir(".gooseweb");
    map_text.clear();
    uses_sqlite = false;
    component_errors = 0;
    gen_components(dev);
    if is_dir("lib") { scan_lib_for_sqlite(); }
    if is_dir("lib") { c_symlink("../lib", ".gooseweb/lib"); }
    for &d in dirs {
        if d.route {
            var src: u8[>..] = [];
            app_path(src, d.rel, "route.goose");
            var code: u8[>..] = [];
            if copy_prefixed(src, d.route_ns, code) {
                for k in 7 { if defines(code, METHODS[k]) { d.methods |= 1 << k; } }
                if d.methods == 0 { err(src, 0, "route.goose defines none of fn GET(, POST(, PUT(, PATCH(, DELETE(, HEAD(, OPTIONS("); }
            }
        }
        if d.middleware {
            var src: u8[>..] = [];
            app_path(src, d.rel, "middleware.goose");
            var code: u8[>..] = [];
            if copy_prefixed(src, d.mw_ns, code) {
                d.has_before = defines(code, "before");
                d.has_after = defines(code, "after");
                if !d.has_before && !d.has_after { err(src, 0, "middleware.goose defines neither fn before( nor fn after("); }
            }
        }
        if d.layout {
            var src: u8[>..] = [];
            app_path(src, d.rel, "layout.html");
            var imports: u8[>..] = [];
            add_default_imports(imports);
            gen_template(src, d.layout_ns, d.layout_ns,
                         "fn render<F>(out: u8[>..]&, req: const http::Request&, ctx: const web::Ctx&)", imports, true);
        }
        if d.page_html {
            var imports: u8[>..] = [];
            if d.page_goose {
                var src: u8[>..] = [];
                app_path(src, d.rel, "page.goose");
                var code: u8[>..] = [];
                if copy_prefixed(src, d.page_ns, code) {
                    d.has_load = defines(code, "load");
                    imports_of(code, imports);
                }
            }
            add_default_imports(imports);
            var src: u8[>..] = [];
            app_path(src, d.rel, "page.html");
            var base: u8[>..] = [];
            format(base, d.page_ns, "_html");
            let sig = if d.has_load { "fn render<P>(out: u8[>..]&, req: const http::Request&, ctx: const web::Ctx&, props: const P&)" }
                      else { "fn render(out: u8[>..]&, req: const http::Request&, ctx: const web::Ctx&)" };
            gen_template(src, d.page_ns, base, sig, imports, false);
        }
    }
    if has_not_found {
        var imports: u8[>..] = [];
        add_default_imports(imports);
        gen_template("app/not-found.html", "nf", "nf", "fn render(out: u8[>..]&, req: const http::Request&, ctx: const web::Ctx&)", imports, false);
    }
    if has_state {
        var code: u8[>..] = [];
        if copy_prefixed("app/state.goose", "state", code) {
            has_state_init = defines(code, "init");
            for name in ["handle"] { if !defines(code, name) { err("app/state.goose", 0, "state.goose needs fn handle(msg: const Msg&) -> Reply"); } }
            if find(code, "enum Msg") < 0 && find(code, "struct Msg") < 0 { err("app/state.goose", 0, "state.goose needs a type named Msg"); }
            if find(code, "struct Reply") < 0 && find(code, "enum Reply") < 0 { err("app/state.goose", 0, "state.goose needs a type named Reply"); }
        }
    }
    if errors > 0 { return false; }
    let home = goose_web_home();
    write(".gooseweb/main.goose", gen_main(home));
    write(".gooseweb/map.txt", map_text);
    return errors == 0;
}

// ---------------------------------------------------------------- build

fn goose_cmd(out: u8[>..]&) {
    var g: u8[>..] = [];
    if env("GOOSE", g) && g.len > 0 { shq(out, g); } else { out.append("goose"); }
}

// Replaces .gooseweb/<gen> paths in compiler output with the source paths.
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
            if absolute { format(from, abs, ".gooseweb/", gen_name); } else { format(from, ".gooseweb/", gen_name); }
            var next: u8[>..] = [];
            format_replaced(next, cur, from, src);
            cur.clear();
            cur.append(next);
        }
    }
    var lib_from: u8[>..] = [];
    format(lib_from, abs, ".gooseweb/lib/");
    var next: u8[>..] = [];
    format_replaced(next, cur, lib_from, "lib/");
    cur.clear();
    cur.append(next);
    next.clear();
    format_replaced(next, cur, abs, "");
    return component_lines_back(next);
}

// A compiler error at components/Name.gshtml:K past the source's last line is
// in the generated tail: gw_check lines carry `// gw:line N` and point back
// at the markup; any other is "generated code for components/Name.gshtml".
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
            format(gen_path, ".gooseweb/", n, ".goose");
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
            else { format(out, "generated code for components/", n, ".gshtml"); }
            p = e;
        }
        if !done { out.append("components/"); p = at + "components/".len; }
    }
    return out;
}

fn build(debug: bool, dev: bool) -> bool {
    let t0 = clock();
    last_errors.clear();
    if !gen(dev) { return false; }
    var cwd: u8[>..] = [];
    c_cwd(cwd);
    var cmd: u8[>..] = [];
    goose_cmd(cmd);
    cmd.append(" build --color never ");
    if debug { cmd.append("--debug "); }
    cmd.append("-o ");
    var bin: u8[>..] = [];
    format(bin, cwd, "/.gooseweb/server");
    shq(cmd, bin);
    cmd.push(' ');
    var main_path: u8[>..] = [];
    format(main_path, cwd, "/.gooseweb/main.goose");
    shq(cmd, main_path);
    var out: u8[>..] = [];
    let status = c_run(cmd, out);
    let shown = rewrite_errors(out, cwd);
    if status != 0 {
        write_stderr(shown);
        note_errors(shown);
        if shown.len == 0 {
            write_stderr("gweb: goose build failed; is goose on PATH, or GOOSE set?\n");
            note_errors("gweb: goose build failed; is goose on PATH, or GOOSE set?\n");
        }
        return false;
    }
    if component_errors > 0 {
        write_stderr("gweb: the component errors above stop the build\n");
        return false;
    }
    var routes = 0;
    var pages = 0;
    for d in dirs { if d.route { routes += 1; } if d.page_html { pages += 1; } }
    var msg: u8[>..] = [];
    format(msg, "gweb: built .gooseweb/server: ", routes, " routes, ", pages, " pages, ", statics.len, " static files (",
           ((clock() - t0) * 10.0) as i64 as f64 / 10.0, " s)\n");
    write_stdout(msg);
    return true;
}

// ---------------------------------------------------------------- test

// gweb test (DESIGN-ADDENDUM-3, E5): each component's test_* functions, and a
// zero case, run as Goose and as JavaScript (pretty and compact); the state
// and the render must match exactly.
fn test_cmd() -> bool {
    if !gen(false) { return false; }
    if component_errors > 0 { write_stderr("gweb test: fix the component errors above\n"); return false; }
    if component_names.len == 0 { write_stdout("gweb test: no components/*.gshtml here\n"); return true; }
    var probe: u8[>..] = [];
    if c_run("command -v node", probe) != 0 { write_stderr("gweb test needs node\n"); return false; }
    let home = goose_web_home();
    make_dir(".gooseweb/test");
    var main: u8[>..] = [];
    main.append("// Generated by gweb test. Prints each case: its name, the state as JSON, the render.\n");
    main.append("import std;\nimport os;\n");
    main.append("import web from \""); lit(main, home); main.append("\";\n");
    main.append("import net from \""); lit(main, home); main.append("/../goose-net\";\n");
    main.append("import net.http;\nimport web.template;\n");
    for n in component_names { format(main, "import ", n, ";\n"); }
    main.append("fn main() {\n    var out: u8[>..] = [];\n");
    var mjs_components: u8[>..] = [];
    var cases = 0;
    for mode in 2 {
        let compact = mode == 1;
        var dir: u8[>..] = [];
        format(dir, ".gooseweb/test/js-", if compact { "compact" } else { "pretty" });
        make_dir(dir);
        var rt_path: u8[>..] = [];
        format(rt_path, home, if compact { "/client/gwi.min.js" } else { "/client/gwi.js" });
        var rt: u8[>..] = [];
        if !read(rt_path, rt) { return false; }
        var p: u8[>..] = [];
        format(p, dir, "/gwi.real.js");
        write(p, rt);
        p.clear();
        format(p, dir, "/gwi.js");
        write(p, GWI_SHIM);
        for n in component_names {
            var path: u8[>..] = [];
            format(path, "components/", n, ".gshtml");
            var src: u8[>..] = [];
            if !read(path, src) { return false; }
            var g: u8[>..] = [];
            var j: u8[>..] = [];
            var e: u8[>..] = [];
            component::compile(n, path, src, compact, g, j, e);
            p.clear();
            format(p, dir, "/", n, ".js");
            write(p, j);
            if mode == 1 { continue; }
            if mjs_components.len > 0 { mjs_components.push(','); }
            format(mjs_components, "\"", n, "\"");
            let tests = component::test_names();
            for t in concat(split("zero\n", '\n')[..1], split(tests, '\n')) {
                if t.len == 0 { continue; }
                cases += 1;
                format(main, "    { var s = ", n, "::State { .. }; ");
                if t != "zero" { format(main, n, "::", t, "(s); "); }
                format(main, "out.append(\"== ", n, " ", t, "\\n\"); ", n, "::gw_json(out, s); out.push('\\n'); ",
                       n, "::render(out, s); out.append(\"\\n== end\\n\"); }\n");
            }
            var link: u8[>..] = [];
            format(link, ".gooseweb/test/", n, ".goose");
            var target: u8[>..] = [];
            format(target, "../", n, ".goose");
            c_symlink(target, link);
        }
    }
    main.append("    write_stdout(out);\n}\n");
    write(".gooseweb/test/main.goose", main);
    var cwd: u8[>..] = [];
    c_cwd(cwd);
    var cmd: u8[>..] = [];
    goose_cmd(cmd);
    cmd.append(" build --color never -o ");
    var bin: u8[>..] = [];
    format(bin, cwd, "/.gooseweb/test/components_test");
    shq(cmd, bin);
    cmd.push(' ');
    var mp: u8[>..] = [];
    format(mp, cwd, "/.gooseweb/test/main.goose");
    shq(cmd, mp);
    var out: u8[>..] = [];
    if c_run(cmd, out) != 0 {
        var fixed: u8[>..] = [];
        format_replaced(fixed, out, ".gooseweb/test/", ".gooseweb/");
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
    write(".gooseweb/test/goose.out", out);
    var mjs: u8[>..] = [];
    format(mjs, "const COMPONENTS = [", mjs_components, "];\n");
    mjs.append(RUN_MJS);
    write(".gooseweb/test/run.mjs", mjs);
    out.clear();
    let status = c_run("node .gooseweb/test/run.mjs", out);
    write_stdout(out);
    return status == 0;
}

// Component modules under test import this as ./gwi.js: the runtime, plus a
// record of each component(...) call for run.mjs.
let GWI_SHIM = """
export * from "./gwi.real.js";
import { component as register } from "./gwi.real.js";
export function component(name, def) { globalThis.__gw[name] = def; register(name, def); }

""";

// The comparison half of gweb test; .gooseweb/test/run.mjs is COMPONENTS and this.
let RUN_MJS = """
// Generated by gweb test: runs each case in JavaScript and compares it with goose.out.
import fs from "node:fs";
globalThis.document = { addEventListener() {} };
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
      s = def.zero();
      if (c.test !== "zero") def.tests[c.test](s);
      html = def.render(s);
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
            app_path(src, d.rel, "route.goose");
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
            app_path(src, d.rel, "page.html");
            format(line, "  page   GET");
            while line.len < 30 { line.push(' '); }
            format(line, u);
            while line.len < 62 { line.push(' '); }
            format(line, src, "\n");
        }
        write_stdout(line);
    }
    for s in statics {
        var line: u8[>..] = [];
        format(line, "  static GET");
        while line.len < 30 { line.push(' '); }
        format(line, s.url);
        while line.len < 62 { line.push(' '); }
        format(line, s.file, "\n");
        write_stdout(line);
    }
}

// ---------------------------------------------------------------- start and dev

fn server_cmd(extra: u8[:][:], dev: bool) -> u8[>..] {
    var cmd: u8[>..] = [];
    cmd.append("./.gooseweb/server");
    if dev {
        var has_workers = false;
        for a in extra { if a == "--workers" { has_workers = true; } }
        if !has_workers { cmd.append(" --workers 2"); }
        cmd.append(" --log");
        // A fresh build id per spawn: open pages poll it and reload when it changes.
        format(cmd, " --dev-id ", (time() * 1000.0) as i64);
    }
    for a in extra { cmd.push(' '); shq(cmd, a); }
    return cmd;
}

fn stamp() -> i64 {
    var count = 0;
    var newest = 0;
    for dir in ["app", "lib", "public", "components"] { newest = max(newest, c_tree_stamp(dir, count)); }
    return newest * 31 + count;
}

// The running dev server serves this file's text in /__gweb/id; open pages
// show it in an overlay. Empty after a good build.
fn write_dev_errors(text: const u8[:]) {
    make_dir(".gooseweb.dev");
    write_file(".gooseweb.dev/errors.txt", text);
}

fn dev(extra: u8[:][:]) {
    var pid: i64 = -1;
    var last = stamp();
    write_dev_errors("");
    if build(false, true) {
        pid = c_spawn(server_cmd(extra, true));
    } else {
        write_dev_errors(last_errors);
        write_stderr("gweb dev: fix the errors above; watching app/, lib/, public/ and components/\n");
    }
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
        if !build(false, true) {
            write_dev_errors(last_errors);
            write_stderr("gweb dev: build failed; the old server keeps running\n");
            continue;
        }
        write_dev_errors("");
        if pid > 0 { c_kill(pid, 15); c_wait(pid, 1); }
        pid = c_spawn(server_cmd(extra, true));
    }
}

// ---------------------------------------------------------------- new

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
<title>{{ ctx.title }}</title>
<link rel="stylesheet" href="/site.css">
</head>
<body>
<nav><a href="/">Home</a> <a href="/hello/goose">Hello</a> <a href="/api/time">API</a></nav>
<main>
{{slot}}
</main>
</body>
</html>

"""],
        ["app/page.html", """
<h1>goose-web</h1>
<p>Edit <code>app/page.html</code>. Worker {{ ctx.worker }} rendered this page.</p>

"""],
        ["app/hello/[name]/page.goose", """
import std;
import net.http;
import web;

struct Props { name: const u8[:], shout: bool }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    let name = web::param(ctx, "name");
    if name == "nobody" { web::not_found(ctx); return Props { .. }; }
    ctx.title.append("Hello");
    let s, has = http::query_param(req, "shout");
    return Props { name: name, shout: has };
}

"""],
        ["app/hello/[name]/page.html", """
<h1>Hello, {{ props.name }}{{#if props.shout}}!!!{{#else}}.{{/if}}</h1>
<ul>
{{#for i in 3}}
  <li>line {{ i + 1 }}</li>
{{/for}}
</ul>

"""],
        ["app/api/time/route.goose", """
import std;
import net.http;
import web;

fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    web::json(res, http::Status.Ok);
    format(res.body, "{\"unix\":", time() as i64, ",\"worker\":", ctx.worker, "}");
}

"""],
        ["app/not-found.html", """
<h1>Not found</h1>
<p>No page at {{ req.path }}.</p>

"""],
        [".gitignore", ".gooseweb/\n.gooseweb.dev/\n"],
        ["public/site.css", """
body { font-family: system-ui, sans-serif; max-width: 40rem; margin: 2rem auto; }
nav a { margin-right: 1rem; }

"""],
    ];
    for f in files {
        var path: u8[>..] = [];
        format(path, dir, "/", f[0]);
        // make each parent folder
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

fn usage() {
    write_stderr("""
usage: gweb [-C dir] <command>
  new <dir>         make a starter project
  gen               write .gooseweb/ only
  build [--debug]   gen, then goose build to .gooseweb/server
  start [flags]     build, then run the server (flags go to it: --port N --workers N --log ...)
  dev [flags]       build, run, and rebuild on every change under app/, lib/, public/
  routes            print the route table
  test              run each component's test_* functions as Goose and as JavaScript; they must match

""");
    exit(2);
}

fn main() {
    let a = args();
    var i = 1;
    if a.len > 2 && a[1] == "-C" {
        if c_chdir(a[2]) == 0 { err(a[2], 0, "cannot change to this folder"); exit(1); }
        i = 3;
    }
    if i >= a.len { usage(); }
    let cmd = a[i];
    let rest = a[i + 1..];
    if cmd == "new" { if rest.len != 1 { usage(); } scaffold(rest[0]); return; }
    if cmd == "gen" { if !gen(false) || component_errors > 0 { exit(1); } write_stdout("gweb: wrote .gooseweb/\n"); return; }
    if cmd == "test" { if !test_cmd() { exit(1); } return; }
    if cmd == "build" { if !build(rest.len > 0 && rest[0] == "--debug", false) { exit(1); } return; }
    if cmd == "routes" { print_routes(); return; }
    if cmd == "start" {
        if !build(false, false) { exit(1); }
        c_exec(server_cmd(rest, false));
        write_stderr("gweb: could not start .gooseweb/server\n");
        exit(1);
    }
    if cmd == "dev" { dev(rest); return; }
    usage();
}
