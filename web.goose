// web: the runtime of goose-web, a Next.js-like framework on goose-net.
//
// Programs do not call most of this directly: `gweb` scans app/, lib/ and
// public/ and generates a root file (.gooseweb/main.goose) whose dispatcher
// calls the user's route, page and middleware functions. See DESIGN.md.
//
// User functions take (req: const http::Request&, ctx: web::Ctx&, ...);
// see DESIGN-ADDENDUM-1.md for each signature.

namespace web;

import std;
import os;
import net from "../goose-net";
import net.http;
import json;

// ---------------------------------------------------------------- types
//
// The request travels as its own `const http::Request&` parameter, and Ctx
// holds no references or slices (DESIGN-ADDENDUM-1). So a handler may shrink
// res at any time while it still reads req and ctx.

// Route parameters from dynamic segments: app/todos/[id]/ gives "id". The
// values are copies.
struct Params { n: i64, names: u8[..32][8], values: u8[..256][8] }

// What a handler, loader or middleware decided. The generated finish()
// applies it after the route or page.
enum Outcome { Continue, NotFound, Redirect }

// One request's context.
struct Ctx {
    params: Params,
    worker: i64,              // 0..workers-1
    owner_fd: i32,            // this worker's channel to the state owner, -1 without app/state.goose
    outcome: Outcome,
    redirect_status: i64,
    location: u8[..1024],
    title: u8[..256],         // set by page loaders, read by layouts
    set_cookies: u8[..2048]   // pending Set-Cookie lines; run_worker moves them to res (DESIGN-ADDENDUM-5)
}

// Server settings, from flags and the environment (config_from_args).
struct Config { port: i64, host: u8[..64], workers: i64, log: bool, idle_ms: i64, max_body: i64,
                dev_id: i64 }   // gweb dev's build id (0 = off): serves /__gweb/id and injects live reload

fn no_params() -> Params { Params { n: 0, names: [""; 8], values: [""; 8] } }

fn new_ctx(worker: i64, owner_fd: i32) -> Ctx {
    Ctx { params: no_params(), worker: worker, owner_fd: owner_fd, outcome: Outcome.Continue,
          redirect_status: 302, location: "", title: "", set_cookies: "" }
}

// ---------------------------------------------------------------- params and query

// Records a dynamic segment. False when the value is over 256 bytes, the
// name over 32, or there are already 8; the dispatcher then answers 404.
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
    return "";
}

// A route parameter as an integer.
fn param_int(ctx: const Ctx&, name: const u8[:]) -> i64, bool {
    let v = param(ctx, name);
    if v.len == 0 { return 0, false; }
    return parse_int(v);
}

// A query parameter, URL-decoded and appended to out. False when absent.
fn query(req: const http::Request&, name: const u8[:], out: u8[>..]&) -> bool {
    let v, has = http::query_param(req, name);
    if has { http::url_decode(out, v); }
    return has;
}

// Splits a path into at most 16 segments ("/a/b" gives "a", "b"; "/" gives
// none). seg gets each segment and starts/ends its offsets in path. Returns
// the count, or 17 when there are more than 16.
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

// ---------------------------------------------------------------- cookies (DESIGN-ADDENDUM-5)
//
// Reading goes through req; setting goes through ctx, so it works the same
// in handlers, loaders and middleware. Ctx keeps the finished Set-Cookie
// lines (flat bytes, no slices) and run_worker moves them to res.headers
// after the dispatcher returns.

enum SameSite { Lax, Strict, None }

// The attributes of a cookie to set. The defaults give a host-only session
// cookie for the whole site that scripts cannot read.
struct CookieOptions {
    path: u8[..128] = "/",
    domain: u8[..128] = "",             // "" = this host only
    max_age: i64 = -1,                  // seconds; -1 = until the browser closes
    secure: bool = false,               // HTTPS only
    http_only: bool = true,             // hidden from document.cookie
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

// A request cookie, percent-decoded and appended to out. False when absent.
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

// A request cookie as sent (not decoded), or fallback when it is absent or
// empty. One value, so templates and layouts can use it.
fn cookie_or(req: const http::Request&, name: const u8[:], fallback: const u8[:]) -> const u8[:] {
    let v, has = http::cookie(req, name);
    if has && v.len > 0 { return v; }
    return fallback;
}

// A request cookie as an integer.
fn cookie_int(req: const http::Request&, name: const u8[:]) -> i64, bool {
    let v, has = http::cookie(req, name);
    if !has || v.len == 0 { return 0, false; }
    return parse_int(v);
}

// Sets a cookie on this response. The value may be any bytes; it is
// percent-encoded. False, with nothing set, when the name is not 1 to 64
// token bytes, the encoded value is over 1024 bytes, an option is invalid, a
// __Secure- or __Host- name breaks its rule, or the response's cookies would
// pass 2048 bytes.
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

// Tells the browser to delete a cookie. Pass the path and domain (and, for a
// __Secure- or __Host- name, secure) it was set with; max_age is ignored.
fn clear_cookie(ctx: Ctx&, name: const u8[:], opts: CookieOptions = CookieOptions { .. }) -> bool {
    var o = opts;
    o.max_age = 0;
    return set_cookie(ctx, name, "", o);
}

// Moves the pending Set-Cookie lines to res.headers. False when they do not
// fit beside the headers already there: the reply then becomes a 500 with no
// cookies, so a cookie is never dropped silently. run_worker calls this
// after the dispatcher.
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

// Sets an HTML reply. Write the HTML into res.body.
fn html(res: http::Response&, status: http::Status) {
    res.status = status;
    res.content_type.clear();
    res.content_type.append("text/html; charset=utf-8");
}

// Sets a JSON reply. Write the JSON into res.body.
fn json(res: http::Response&, status: http::Status) { http::json_reply(res, status); }

// Marks the request as not found; finish() renders the 404 page.
fn not_found(ctx: Ctx&) { ctx.outcome = Outcome.NotFound; }

// Redirects to `to`; finish() writes the status and Location.
fn redirect(ctx: Ctx&, to: const u8[:], status: i64 = 302) {
    ctx.outcome = Outcome.Redirect;
    ctx.redirect_status = status;
    ctx.location.clear();
    ctx.location.append(to[..min(to.len, 1024)]);
}

// Applies a Redirect outcome to res. finish() calls this.
fn apply_redirect(ctx: const Ctx&, res: http::Response&) {
    res.status = http::status_from_code(ctx.redirect_status);
    res.content_type.clear();
    res.body.clear();
    http::set_header(res, "Location", ctx.location);
}

// 204 with Allow, for OPTIONS without a handler.
fn options(res: http::Response&, allow: const u8[:]) {
    res.status = http::Status.NoContent;
    http::set_header(res, "Allow", allow);
}

// 405 with Allow.
fn method_not_allowed(res: http::Response&, allow: const u8[:]) {
    http::json_error(res, http::Status.MethodNotAllowed, "method not allowed");
    http::set_header(res, "Allow", allow);
}

// The plain 404, used when there is no app/not-found.html.
fn plain_not_found(res: http::Response&) {
    http::text(res, http::Status.NotFound, "404 not found\n");
}

// ---------------------------------------------------------------- config

extern fn c_performance_cores() -> i64 = "gweb_performance_cores";

// The default worker count: min(performance cores, 4), or min(hardware
// threads, 4) where performance cores are unknown (DESIGN-ADDENDUM-2, Q1).
fn default_workers() -> i64 {
    let perf = c_performance_cores();
    let cores = if perf > 0 { perf } else { hardware_threads() };
    return max(1, min(cores, 4));
}

fn default_config() -> Config {
    Config { port: 3000, host: "0.0.0.0", workers: default_workers(), log: false,
             idle_ms: 5000, max_body: 1048576, dev_id: 0 }
}

// Reads --port N, --host H, --workers N, --log, --idle-ms N, --max-body N,
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
            if flag == "--dev-id" && ok { cfg.dev_id = n; i += 2; continue; }
            if flag == "--host" { cfg.host.clear(); cfg.host.append(v[..min(v.len, 64)]); i += 2; continue; }
        }
        print("unknown or incomplete flag: ", flag);
        print("flags: --port N --host H --workers N --log --idle-ms N --max-body N (--dev-id N: gweb dev only)");
        exit(2);
    }
    return cfg;
}

// ---------------------------------------------------------------- the worker loop

// One worker: a connection loop on the shared listening socket. For each
// request it calls D(req, ctx, res), the generated dispatcher, which fills
// res and returns the index of a static file to send, or -1. S, the
// generated static table, gives that file's bytes, which go out without a
// copy. Runs forever.
fn run_worker<D, S>(slot: i64, server: net::Socket, owner_fd: i32, cfg: Config) {
    // One worker takes every waiting connection per pass; several take one
    // each, so a burst spreads across them.
    let lp = net::connection_loop(server, cfg.idle_ms, cfg.max_body, if cfg.workers == 1 { 0 } else { 1 });
    var raw: u8[>..] = [];
    loop {
        raw.clear();
        let conn, ev = lp.next(raw);
        var res = http::new_response();
        match ev {
            Request => {
                let req, parsed = http::parse_request(raw);
                var keep = false;
                var static_index = -1;
                var dev_request = false;
                match parsed {
                    Ready => {
                        keep = http::wants_keep_alive(req);
                        let p = req.path;
                        let get_like = req.method == http::Method.Get || req.method == http::Method.Head;
                        if cfg.dev_id != 0 && p == "/__gweb/id" {
                            dev_status(res, cfg.dev_id);
                            dev_request = true;
                        } else if get_like && p.len > 1 && p[p.len - 1] == '/' {
                            // /x/ -> /x, keeping the query.
                            var to: u8[>..] = [];
                            to.append(p[..p.len - 1]);
                            if req.query.len > 0 { to.push('?'); to.append(req.query); }
                            res.status = http::Status.PermanentRedirect;
                            http::set_header(res, "Location", to);
                        } else {
                            var ctx = new_ctx(slot, owner_fd);
                            static_index = D(req, ctx, res);
                            if !apply_cookies(ctx, res) { static_index = -1; }
                            dev_inject(res, cfg.dev_id);
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
            },
            Failed => {},
            _ => {
                let status = match ev {
                    TooLarge => http::Status.PayloadTooLarge,
                    HeadTooLarge => http::Status.HeaderFieldsTooLarge,
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

// ---------------------------------------------------------------- dev live reload (DESIGN-ADDENDUM-3, A and follow-up 1)

// The dev status for /__gweb/id: the build id on line 1, then gweb dev's
// last build errors from .gooseweb.dev/errors.txt (nothing after a good build).
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

// In gweb dev, appends a script to HTML replies that polls /__gweb/id: it
// reloads the page when the id changes and shows errors in an overlay
// (DESIGN-ADDENDUM-3, follow-up 3). Two slots: sys (build failed, or the
// server stopped answering), which the poll sets and clears, and isl (component
// errors), which stays until a click on the overlay or a reload. sys shows
// first. Nothing happens when dev_id is 0.
fn dev_inject(res: http::Response&, dev_id: i64) {
    if dev_id == 0 || !starts_with(res.content_type, "text/html") { return; }
    format(res.body, "<script>(function(){var id=\"", dev_id, "\",fails=0,box,sys=\"\",isl=\"\";\n");
    res.body.append("""function draw(){var t=sys||isl;if(!t){if(box){box.remove();box=null}return}""");
    res.body.push('\n');
    res.body.append("""if(!box){box=document.createElement("pre");box.style.cssText="position:fixed;inset:0;margin:0;padding:24px;background:rgba(20,0,0,.92);color:#fff;font:13px/1.5 monospace;white-space:pre-wrap;overflow:auto;z-index:2147483647";box.onclick=function(){isl="";draw()};document.body.appendChild(box)}""");
    res.body.push('\n');
    res.body.append("""if(box.textContent!==t)box.textContent=t}""");
    res.body.push('\n');
    res.body.append("""addEventListener("gw:error",function(e){isl+=(isl?"\n":"component error (click to dismiss)\n\n")+e.detail;draw()});""");
    res.body.push('\n');
    res.body.append("""setInterval(function(){fetch("/__gweb/id",{cache:"no-store"}).then(function(r){return r.text()}).then(function(t){fails=0;var n=t.indexOf("\n"),cur=n<0?t:t.slice(0,n),errs=n<0?"":t.slice(n+1);if(cur!==id){location.reload();return}sys=errs.trim()?"build failed\n\n"+errs:"";draw()}).catch(function(){if(++fails>=4){sys="gweb dev: the server is not responding";draw()}})},500)})();</script>""");
}

// The static table for an app without public/: no files.
fn no_static(i: i64) -> const u8[:] { "" }
