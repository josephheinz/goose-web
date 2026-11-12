// web: the runtime of goose-web, a Next.js-like framework on goose-net.
// `gweb` generates the root file whose dispatcher calls the user's routes, pages and middleware.

namespace web;

import std;
import os;
import net;   // the root file declares it: import net from "OWNER/goose-net@<tag>";
import net.http;
import json;

// ---------------------------------------------------------------- types

struct Params { n: i64, names: u8[..32][8], values: u8[..256][8],
                rest_name: u8[..32] = "", rest: u8[..1024] = "" }   // the catch-all tail has its own, larger field

enum Outcome { Continue, NotFound, Redirect }

// Ctx holds no references or slices, so a handler may shrink res while it still reads req and ctx.
struct Ctx {
    params: Params,
    worker: i64,
    owner_fd: i32,            // -1 without app/state.goose
    outcome: Outcome,
    fragment: bool = false,   // fragment replies get no dev script
    csrf: u8[..32] = "",      // the page's CSRF token; "" until web::csrf_begin
    redirect_status: i64,
    location: u8[..1024],
    title: u8[..256],
    set_cookies: u8[..2048],  // pending Set-Cookie lines; run_worker moves them to res
    status: i64 = 0,          // a page's status override; 0 = none (set_status, unprocessable)
    spool: u8[..256] = "",    // the spool file of an Event.Spooled request; "" otherwise. run_worker deletes it after the reply
    uploads: Upload[..8] = [],        // the files multipart_begin wrote; run_worker deletes the unsaved ones after the reply
    upload_dir: u8[..256] = ""        // where multipart_begin puts them (Config.upload_dir); set by run_worker
}

// A file of a multipart post (web::upload). Lives here because Ctx holds it.
struct Upload {
    field: u8[..64],
    filename: u8[..128],       // as the client sent it, control bytes removed; never a path to trust
    content_type: u8[..96],    // as the client sent it
    size: i64,
    path: u8[..256]            // the temp file; "" when no file was sent
}

struct Config { port: i64, host: u8[..64], workers: i64, log: bool, idle_ms: i64, max_body: i64,
                dev_id: i64,        // 0 = off
                max_upload: i64,    // multipart bodies may be this large (--max-upload)
                spool_over: i64,    // a multipart body over this many bytes is spooled to a file
                upload_dir: u8[..256] }   // spool and upload files (--upload-dir); one server per dir

fn no_params() -> Params { Params { n: 0, names: [""; 8], values: [""; 8] } }

fn new_ctx(worker: i64, owner_fd: i32) -> Ctx {
    Ctx { params: no_params(), worker: worker, owner_fd: owner_fd, outcome: Outcome.Continue,
          redirect_status: 302, location: "", title: "", set_cookies: "" }
}

// ---------------------------------------------------------------- params and query

// False, and the dispatcher answers 404, when a limit is exceeded: 8 params, 32-byte name, 256-byte value.
fn set_param(ctx: Ctx&, name: const u8[:], value: const u8[:]) -> bool {
    let i = ctx.params.n;
    if i >= 8 || name.len > 32 || value.len > 256 { return false; }
    ctx.params.names[i].clear();
    ctx.params.names[i].append(name);
    ctx.params.values[i].clear();
    ctx.params.values[i].append(value);
    ctx.params.n += 1;
    return true;
}

// A route parameter as it appeared in the path (not URL-decoded); "" when absent.
fn param(ctx: const Ctx&, name: const u8[:]) -> const u8[:] {
    for i in ctx.params.n {
        if ctx.params.names[i] == name { return ctx.params.values[i]; }
    }
    if ctx.params.rest_name == name { return ctx.params.rest; }
    return "";
}

fn param_int(ctx: const Ctx&, name: const u8[:]) -> i64, bool {
    let v = param(ctx, name);
    if v.len == 0 { return 0, false; }
    return parse_int(v);
}

// The decoded byte at i and the bytes it spans; -1 for a % without two hex digits.
fn path_byte(s: const u8[:], i: i64) -> i64, i64 {
    if s[i] != '%' { return s[i], 1; }
    if i + 2 < s.len && ascii::hex_value(s[i + 1]) >= 0 && ascii::hex_value(s[i + 2]) >= 0 {
        return (ascii::hex_value(s[i + 1]) * 16 + ascii::hex_value(s[i + 2])), 3;
    }
    return -1, 0;
}

// True when every decoded byte is allowed: not / or \ or a control byte, and no segment decodes to . or ..
// Raw slashes separate segments.
fn path_valid(s: const u8[:]) -> bool {
    var i = 0;
    var seg_len = 0;
    var dots = 0;
    while i <= s.len {
        if i == s.len || s[i] == '/' {
            if seg_len > 0 && seg_len == dots && dots <= 2 { return false; }
            seg_len = 0;
            dots = 0;
            i += 1;
        } else {
            let b, width = path_byte(s, i);
            if b < 32 || b == 127 || b == '/' || b == '\\' { return false; }
            seg_len += 1;
            if b == '.' { dots += 1; }
            i += width;
        }
    }
    return true;
}

// Appends s with %XX decoded; + stays +. False, with nothing appended, on a malformed %, a decoded / or \
// or control byte, or a segment that decodes to . or ..
fn path_decode(out: u8[>..]&, s: const u8[:]) -> bool {
    if !path_valid(s) { return false; }
    var i = 0;
    while i < s.len {
        let b, width = path_byte(s, i);
        out.push(b as u8);
        i += width;
    }
    return true;
}

// Called by the generated dispatcher. False, and the dispatcher answers 404, when the name or tail is over its
// limit, a segment is empty, or path_decode would refuse the tail; "" is a valid tail.
fn set_rest(ctx: Ctx&, name: const u8[:], rest: const u8[:]) -> bool {
    if name.len > 32 || rest.len > 1024 { return false; }
    if rest.len > 0 {
        if rest[0] == '/' || rest[rest.len - 1] == '/' { return false; }
        for i in 1..rest.len {
            if rest[i] == '/' && rest[i - 1] == '/' { return false; }
        }
    }
    if !path_valid(rest) { return false; }
    ctx.params.rest_name.clear();
    ctx.params.rest_name.append(name);
    ctx.params.rest.clear();
    ctx.params.rest.append(rest);
    return true;
}

// Appends the URL-decoded value to out; false when absent.
fn query(req: const http::Request&, name: const u8[:], out: u8[>..]&) -> bool {
    let v, has = http::query_param(req, name);
    if has { http::url_decode(out, v); }
    return has;
}

// Returns the segment count, or 17 when there are more than 16; starts and ends are offsets into path.
fn split(path: const u8[:], seg: const u8[:][16]&, starts: i64[16]&, ends: i64[16]&) -> i64 {
    var n = 0;
    var start = 1;
    if path.len <= 1 { return 0; }
    for i in 1..path.len + 1 {
        if i == path.len || path[i] == '/' {
            if n >= 16 { return 17; }
            seg[n] = path[start..i];
            starts[n] = start;
            ends[n] = i;
            n += 1;
            start = i + 1;
        }
    }
    return n;
}

// ---------------------------------------------------------------- cookies
// Ctx holds the finished Set-Cookie lines (flat bytes, no slices); run_worker moves them to res.headers after the dispatcher returns.

enum SameSite { Lax, Strict, None }

struct CookieOptions {
    path: u8[..128] = "/",
    domain: u8[..128] = "",             // "" = this host only
    max_age: i64 = -1,                  // seconds; -1 = until the browser closes
    secure: bool = false,
    http_only: bool = true,
    same_site: SameSite = SameSite.Lax
}

const COOKIE_NAME_MAX = 64;
const COOKIE_VALUE_MAX = 1024;          // after encoding

let COOKIE_NAME_BYTES = byte_set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~");
let COOKIE_PLAIN_BYTES = byte_set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~");
let COOKIE_DOMAIN_BYTES = byte_set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.");
let HEX_UPPER = "0123456789ABCDEF";

fn all_in(s: const u8[:], set: const ByteSet&) -> bool {
    for c in s { if !set.members[c] { return false; } }
    return true;
}

// Appends the percent-decoded value to out; false when absent.
fn cookie(req: const http::Request&, name: const u8[:], out: u8[>..]&) -> bool {
    let v, has = http::cookie(req, name);
    if !has { return false; }
    var i = 0;
    while i < v.len {
        if v[i] == '%' && i + 2 < v.len && ascii::hex_value(v[i + 1]) >= 0 && ascii::hex_value(v[i + 2]) >= 0 {
            out.push((ascii::hex_value(v[i + 1]) * 16 + ascii::hex_value(v[i + 2])) as u8);
            i += 3;
        } else { out.push(v[i]); i += 1; }
    }
    return true;
}

// The value as sent (not decoded), or fallback when absent or empty.
fn cookie_or(req: const http::Request&, name: const u8[:], fallback: const u8[:]) -> const u8[:] {
    let v, has = http::cookie(req, name);
    if has && v.len > 0 { return v; }
    return fallback;
}

fn cookie_int(req: const http::Request&, name: const u8[:]) -> i64, bool {
    let v, has = http::cookie(req, name);
    if !has || v.len == 0 { return 0, false; }
    return parse_int(v);
}

// The value is percent-encoded. False, with nothing set, when an argument or option is invalid,
// a __Secure- or __Host- name breaks its rule, or the response's cookies would pass 2048 bytes.
fn set_cookie(ctx: Ctx&, name: const u8[:], value: const u8[:], opts: CookieOptions = CookieOptions { .. }) -> bool {
    let secure = opts.secure || opts.same_site == SameSite.None;
    if name.len == 0 || name.len > COOKIE_NAME_MAX || !all_in(name, COOKIE_NAME_BYTES) { return false; }
    if opts.path.len == 0 || opts.path[0] != '/' { return false; }
    for c in opts.path { if c <= ' ' || c >= 127 || c == ';' { return false; } }
    if !all_in(opts.domain, COOKIE_DOMAIN_BYTES) || opts.max_age < -1 { return false; }
    if starts_with(name, "__Secure-") && !secure { return false; }
    if starts_with(name, "__Host-") && (!secure || opts.path != "/" || opts.domain.len > 0) { return false; }
    var encoded = 0;
    for c in value { encoded += if COOKIE_PLAIN_BYTES.members[c] { 1 } else { 3 }; }
    if encoded > COOKIE_VALUE_MAX { return false; }

    var line: u8[..1536] = "";
    format(line, "Set-Cookie: ", name, "=");
    for c in value {
        if COOKIE_PLAIN_BYTES.members[c] { line.push(c); }
        else { line.push('%'); line.push(HEX_UPPER[c >> 4]); line.push(HEX_UPPER[c & 15]); }
    }
    format(line, "; Path=", opts.path);
    if opts.domain.len > 0 { format(line, "; Domain=", opts.domain); }
    if opts.max_age >= 0 { format(line, "; Max-Age=", opts.max_age); }
    if opts.max_age == 0 { line.append("; Expires=Thu, 01 Jan 1970 00:00:00 GMT"); }
    if secure { line.append("; Secure"); }
    if opts.http_only { line.append("; HttpOnly"); }
    line.append(match opts.same_site { Lax => "; SameSite=Lax", Strict => "; SameSite=Strict", None => "; SameSite=None" });
    line.append("\r\n");
    if line.len > ctx.set_cookies.cap - ctx.set_cookies.len { return false; }
    ctx.set_cookies.append(line);
    return true;
}

// Pass the path and domain (and secure, for __Secure-/__Host- names) the cookie was set with; max_age is ignored.
fn clear_cookie(ctx: Ctx&, name: const u8[:], opts: CookieOptions = CookieOptions { .. }) -> bool {
    var o = opts;
    o.max_age = 0;
    return set_cookie(ctx, name, "", o);
}

// False when the lines do not fit beside res.headers: the reply becomes a 500 with no cookies, so a cookie is never dropped silently.
fn apply_cookies(ctx: Ctx&, res: http::Response&) -> bool {
    if ctx.set_cookies.len == 0 { return true; }
    if ctx.set_cookies.len > res.headers.cap - res.headers.len {
        ctx.set_cookies.clear();
        res.headers.clear();
        http::json_error(res, http::Status.InternalServerError, "response headers too large");
        return false;
    }
    res.headers.append(ctx.set_cookies);
    ctx.set_cookies.clear();
    return true;
}

// ---------------------------------------------------------------- responses

fn html(res: http::Response&, status: http::Status) {
    res.status = status;
    res.content_type.clear();
    res.content_type.append("text/html; charset=utf-8");
}

fn json(res: http::Response&, status: http::Status) { http::json_reply(res, status); }

fn not_found(ctx: Ctx&) { ctx.outcome = Outcome.NotFound; }

// The generated page function applies a nonzero status after rendering, while the outcome is Continue.
fn set_status(ctx: Ctx&, code: i64) { ctx.status = code; }

fn unprocessable(ctx: Ctx&) { ctx.status = 422; }

fn redirect(ctx: Ctx&, to: const u8[:], status: i64 = 302) {
    ctx.outcome = Outcome.Redirect;
    ctx.redirect_status = status;
    ctx.location.clear();
    ctx.location.append(to[..min(to.len, 1024)]);
}

fn apply_redirect(ctx: const Ctx&, res: http::Response&) {
    res.status = http::status_from_code(ctx.redirect_status);
    res.content_type.clear();
    res.body.clear();
    http::set_header(res, "Location", ctx.location);
}

fn options(res: http::Response&, allow: const u8[:]) {
    res.status = http::Status.NoContent;
    http::set_header(res, "Allow", allow);
}

fn method_not_allowed(res: http::Response&, allow: const u8[:]) {
    http::json_error(res, http::Status.MethodNotAllowed, "method not allowed");
    http::set_header(res, "Allow", allow);
}

fn plain_not_found(res: http::Response&) {
    http::text(res, http::Status.NotFound, "404 not found\n");
}

// The request's Content-Length: 0 when absent, -1 when malformed. Pages with MAX_UPLOAD compare it before reading the body.
fn content_length(req: const http::Request&) -> i64 { return http::content_length(req.head); }

// ---------------------------------------------------------------- config

extern fn c_up_mkdir(path: const u8[:]) -> i32 = "gweb_up_mkdir";
extern fn c_up_sweep(dir: const u8[:]) -> i64 = "gweb_up_sweep";
extern fn c_up_unlink(path: const u8[:]) -> i32 = "gweb_up_unlink";

extern fn c_performance_cores() -> i64 = "gweb_performance_cores";

// min(performance cores, 4); hardware threads where cores are unknown.
fn default_workers() -> i64 {
    let perf = c_performance_cores();
    let cores = if perf > 0 { perf } else { hardware_threads() };
    return max(1, min(cores, 4));
}

fn default_config() -> Config {
    Config { port: 3000, host: "0.0.0.0", workers: default_workers(), log: false,
             idle_ms: 5000, max_body: 1048576, dev_id: 0,
             max_upload: 33554432, spool_over: 65536, upload_dir: ".gooseweb.uploads" }
}

// Reads --port N, --host H, --workers N, --log, --idle-ms N, --max-body N, --max-upload N, --upload-dir D,
// and the PORT and WEB_WORKERS environment variables (flags win).
fn config_from_args() -> Config {
    var cfg = default_config();
    var e: u8[>..] = [];
    if env("PORT", e) { let p, ok = parse_int(trim(e)); if ok { cfg.port = p; } }
    e.clear();
    if env("WEB_WORKERS", e) { let w, ok = parse_int(trim(e)); if ok && w > 0 { cfg.workers = w; } }
    let a = args();
    var i = 1;
    while i < a.len {
        let flag = a[i];
        let has_value = i + 1 < a.len;
        if flag == "--log" { cfg.log = true; i += 1; continue; }
        if has_value {
            let v = a[i + 1];
            let n, ok = parse_int(v);
            if flag == "--port" && ok { cfg.port = n; i += 2; continue; }
            if flag == "--workers" && ok && n > 0 { cfg.workers = n; i += 2; continue; }
            if flag == "--idle-ms" && ok { cfg.idle_ms = n; i += 2; continue; }
            if flag == "--max-body" && ok { cfg.max_body = n; i += 2; continue; }
            if flag == "--max-upload" && ok && n > 0 { cfg.max_upload = n; i += 2; continue; }
            if flag == "--dev-id" && ok { cfg.dev_id = n; i += 2; continue; }
            if flag == "--upload-dir" && v.len > 0 && v.len <= 256 { cfg.upload_dir.clear(); cfg.upload_dir.append(v); i += 2; continue; }
            if flag == "--host" { cfg.host.clear(); cfg.host.append(v[..min(v.len, 64)]); i += 2; continue; }
        }
        print("unknown or incomplete flag: ", flag);
        print("flags: --port N --host H --workers N --log --idle-ms N --max-body N --max-upload N --upload-dir D (--dev-id N: gweb dev only)");
        exit(2);
    }
    return cfg;
}

// ---------------------------------------------------------------- the worker loop

// D, the generated dispatcher, returns the index of a static file to send, or -1; S gives its bytes, sent without a copy. Never returns.
fn run_worker<D, S>(slot: i64, server: net::Socket, owner_fd: i32, cfg: Config) {
    // One worker takes every waiting connection per pass; several take one each, so a burst spreads.
    let lp = net::connection_loop(server, cfg.idle_ms, cfg.max_body, if cfg.workers == 1 { 0 } else { 1 });
    // Uploads: make the directory, let slot 0 delete files an earlier run left (names gnet-* and gw-*), then opt in.
    // Without a usable directory a multipart body stays in memory, up to --max-body.
    if cfg.upload_dir.len > 0 && c_up_mkdir(cfg.upload_dir) != 0 {
        if slot == 0 { c_up_sweep(cfg.upload_dir); }
        if !lp.set_uploads(cfg.max_upload, cfg.spool_over, cfg.upload_dir) {
            print("warning: cannot use upload dir ", cfg.upload_dir, "; uploads are limited to --max-body");
        }
    } else {
        print("warning: cannot create upload dir ", cfg.upload_dir, "; uploads are limited to --max-body");
    }
    var raw: u8[>..] = [];
    loop {
        raw.clear();
        let conn, ev = lp.next(raw);
        var res = http::new_response();
        match ev {
            Request, Spooled => {
                var ctx = new_ctx(slot, owner_fd);
                ctx.upload_dir.append(cfg.upload_dir);
                var spool_ok = true;
                if ev == net::Event.Spooled {
                    var sp: u8[>..] = [];
                    lp.spool_path(sp);
                    if sp.len > ctx.spool.cap { c_up_unlink(sp); spool_ok = false; } else { ctx.spool.append(sp); }
                }
                let req, parsed = http::parse_request(raw);
                var keep = false;
                var static_index = -1;
                var dev_request = false;
                match parsed {
                    Ready => {
                        keep = http::wants_keep_alive(req);
                        let p = req.path;
                        let get_like = req.method == http::Method.Get || req.method == http::Method.Head;
                        if !spool_ok {
                            http::json_error(res, http::Status.InternalServerError, http::reason(http::Status.InternalServerError));
                        } else if cfg.dev_id != 0 && p == "/__gweb/id" {
                            dev_status(res, cfg.dev_id);
                            dev_request = true;
                        } else if get_like && p.len > 1 && p[p.len - 1] == '/' {
                            var to: u8[>..] = [];
                            to.append(p[..p.len - 1]);
                            if req.query.len > 0 { to.push('?'); to.append(req.query); }
                            res.status = http::Status.PermanentRedirect;
                            http::set_header(res, "Location", to);
                        } else {
                            static_index = D(req, ctx, res);
                            if !apply_cookies(ctx, res) { static_index = -1; }
                            if !ctx.fragment { dev_inject(res, cfg.dev_id); }
                        }
                    },
                    Reject r => http::json_error(res, r.status, http::reason(r.status)),
                    Closed => {},
                }
                let head_only = req.method == http::Method.Head;
                let sent = if static_index >= 0 {
                    http::send_response_with(conn, res, S(static_index), head_only, keep)
                } else {
                    http::send_response(conn, res, head_only, keep)
                };
                if cfg.log && !dev_request { print("[", slot, "] ", req.method_text, " ", req.target, " -> ", res.status); }
                if !sent || !keep { lp.close_connection(conn); }
                // The reply is out: delete the spool file and every upload not saved (a saved one is gone, so its unlink fails harmlessly).
                if ctx.spool.len > 0 { c_up_unlink(ctx.spool); }
                for i in ctx.uploads.len {
                    if ctx.uploads[i].path.len > 0 { c_up_unlink(ctx.uploads[i].path); }
                }
            },
            Failed => {},
            _ => {
                let status = match ev {
                    TooLarge => http::Status.PayloadTooLarge,
                    HeadTooLarge => http::Status.HeaderFieldsTooLarge,
                    SpoolFailed => http::Status.InternalServerError,
                    Unsupported => http::Status.NotImplemented,
                    _ => http::Status.BadRequest,
                };
                http::json_error(res, status, http::reason(status));
                http::send_response(conn, res);
                lp.close_connection(conn);
            },
        }
    }
}

// ---------------------------------------------------------------- dev live reload

// Line 1 is the build id; the rest is gweb dev's last build errors (empty after a good build).
fn dev_status(res: http::Response&, dev_id: i64) {
    http::text(res, http::Status.Ok, "");
    format(res.body, dev_id);
    var errs: u8[>..] = [];
    if read_file(".gooseweb.dev/errors.txt", errs) && errs.len > 0 {
        res.body.push('\n');
        res.body.append(errs);
    }
    http::set_header(res, "Cache-Control", "no-store");
}

// Appends the dev script that polls /__gweb/id: reload on a new id, error overlay otherwise.
// Two overlay slots: sys (build failed or server down; the poll sets and clears it) and isl
// (page errors; cleared by a click or reload). sys shows first.
fn dev_inject(res: http::Response&, dev_id: i64) {
    if dev_id == 0 || !starts_with(res.content_type, "text/html") { return; }
    format(res.body, "<script>(function(){var id=\"", dev_id, "\",fails=0,box,sys=\"\",isl=\"\";\n");
    res.body.append("""function draw(){var t=sys||isl;if(!t){if(box){box.remove();box=null}return}""");
    res.body.push('\n');
    res.body.append("""if(!box){box=document.createElement("pre");box.style.cssText="position:fixed;inset:0;margin:0;padding:24px;background:rgba(20,0,0,.92);color:#fff;font:13px/1.5 monospace;white-space:pre-wrap;overflow:auto;z-index:2147483647";box.onclick=function(){isl="";draw()};document.body.appendChild(box)}""");
    res.body.push('\n');
    res.body.append("""if(box.textContent!==t)box.textContent=t}""");
    res.body.push('\n');
    res.body.append("""addEventListener("gw:error",function(e){isl+=(isl?"\n":"page error (click to dismiss)\n\n")+e.detail;draw()});""");
    res.body.push('\n');
    res.body.append("""setInterval(function(){fetch("/__gweb/id",{cache:"no-store"}).then(function(r){return r.text()}).then(function(t){fails=0;var n=t.indexOf("\n"),cur=n<0?t:t.slice(0,n),errs=n<0?"":t.slice(n+1);if(cur!==id){location.reload();return}sys=errs.trim()?"build failed\n\n"+errs:"";draw()}).catch(function(){if(++fails>=4){sys="gweb dev: the server is not responding";draw()}})},500)})();</script>""");
}

fn no_static(i: i64) -> const u8[:] { "" }
