// gweb: the runtime of gweb, a Next.js-like framework on goose-net.
// `gweb` generates the root file whose dispatcher calls the user's routes, pages and middleware.

namespace gweb;

import std;
import os;
import net;   // the root file declares it: import net from "OWNER/goose-net@<tag>";
import net.http;
import net.hub;
import net.lifecycle;
import json;

// ---------------------------------------------------------------- types

struct Params { n: i64, names: u8[..32][8], values: u8[..256][8],
                rest_name: u8[..32] = "", rest: u8[..1024] = "" }   // the catch-all tail has its own, larger field

enum Outcome { Continue, NotFound, Redirect, Error, Done }

// Declared here, before Ctx and Config use them (DESIGN-ADDENDUM-13, D2).
struct Keys { n: i64 = 0, k: u8[..64][4] = [""; 4] }   // the first key signs, all verify
struct AuthConfig { keys: Keys = Keys { .. }, idle: i64 = 86400, max: i64 = 2592000, trust_proxy: bool = false }

// A signed session cookie, loaded lazily by gweb::session (DESIGN-ADDENDUM-13, D4).
enum SessionState { Unread, Absent, Valid }
struct Session { state: SessionState = SessionState.Unread, sid: u8[..22] = "", uid: i64 = 0, ver: i64 = 0,
                 iat: i64 = 0, exp: i64 = 0, remember: bool = false, data: u8[..256] = "" }

// What run_worker does with the connection after the handler: hand it to the hub as an SSE stream or a WebSocket.
enum Detach { None, Stream, WebSocket }

// Fixed-size fields, so Ctx stays free of references; the setters in meta.goose cut at a UTF-8 boundary.
struct Meta { description: u8[..320] = "", canonical: u8[..512] = "", image: u8[..512] = "", robots: u8[..64] = "" }

enum Level { Debug, Info, Warn, Error }

// Ctx holds no references or slices, so a handler may shrink res while it still reads req and ctx.
struct Ctx {
    params: Params,
    worker: i64,
    owner_fd: i32,            // -1 without app/state.goose
    outcome: Outcome,
    fragment: bool = false,   // fragment replies get no dev script
    csrf: u8[..32] = "",      // the page's CSRF token; "" until gweb::csrf_begin
    locale: i64 = 0,          // index into the generated t::TAGS; 0 is the default locale
    redirect_status: i64,
    location: u8[..1024],
    title: u8[..256],
    meta: Meta,
    set_cookies: u8[..2048],  // pending Set-Cookie lines; run_worker moves them to res
    status: i64 = 0,          // a page's status override; 0 = none (set_status, unprocessable)
    spool: u8[..256] = "",    // the spool file of an Event.Spooled request; "" otherwise. run_worker deletes it after the reply
    uploads: Upload[..8] = [],        // the files multipart_begin wrote; run_worker deletes the unsaved ones after the reply
    upload_dir: u8[..256] = "",       // where multipart_begin puts them (Config.upload_dir); set by run_worker
    route: i64 = -1,                  // the dispatcher's matched dir index; finish picks the nearest error.html with it
    error_status: i64 = 0,            // gweb::fail's status and message, read by the generated error_reply
    error_message: u8[..512] = "",
    auth: AuthConfig = AuthConfig { .. }, // copied from Config by run_worker; the keys live here so handlers need no globals
    session: Session = Session { .. },
    conn_fd: i32 = -1,        // the worker's connection, for rate::client_ip and gweb::stream_begin
    default_headers: bool = true,   // false: the handler writes its own frame and sniffing headers
    nonce: u8[..24] = "",     // the CSP nonce; "" until run_worker or gweb::csp_begin makes it
    streamed: bool = false,   // the handler sent its own reply through a Stream
    stream_ended: bool = false,
    hub: u64 = 0,             // 0 = no hub in this build
    detach: Detach = Detach.None,
    topic: u8[..64] = "",
    heartbeat: u8[..64] = "",
    route_label: i64 = -1,        // the route's place in ROUTES, for the access log, metrics and spans; -1 = none
    request_id: u8[..64] = "",    // set when the access log or tracing is on
    trace_id: u8[..32] = "",      // set when tracing is on; sampled or not
    span_id: u8[..16] = "",       // the current span: the request's, or the innermost open gweb::span
    parent_span: u8[..16] = "",   // the caller's span from a traceparent header
    sampled: bool = false,
    start_us: i64 = 0,            // monotonic; 0 when nothing needed the time
    job_id: i64 = 0,              // set in a job runner's ctx
    attempt: i64 = 0
}

// A file of a multipart post (gweb::upload). Lives here because Ctx holds it.
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
                upload_dir: u8[..256],    // spool and upload files (--upload-dir); one server per dir
                auth: AuthConfig,
                security_headers: bool, hsts: i64, csp: i64,   // csp: 0 off, 1 on, 2 report-only
                export_dir: u8[..512],   // "" = serve; else the generated main writes the site here and exits
                drain_ms: i64, drain_delay_ms: i64,
                log_format: u8[..8], log_level: u8[..8],   // "text" or "json"; "debug", "info", "warn" or "error"
                metrics: bool, job_runners: i64, job_queue: i64, job_attempts: i64,
                schedule: bool,         // false: jobs run, but no schedule fires
                probe: bool,            // --probe: config_from_args answers it and exits
                hub: u64 = 0 }          // the net::Hub handle; 0 when the app uses no streams or WebSockets

fn _no_params() -> Params { Params { n: 0, names: [""; 8], values: [""; 8] } }

fn _new_ctx(worker: i64, owner_fd: i32, hub: u64 = 0) -> Ctx {
    Ctx { params: _no_params(), worker: worker, owner_fd: owner_fd, outcome: Outcome.Continue,
          redirect_status: 302, location: "", title: "", meta: Meta { .. }, set_cookies: "", hub: hub }
}

// ---------------------------------------------------------------- params and query

// False, and the dispatcher answers 404, when a limit is exceeded: 8 params, 32-byte name, 256-byte value.
fn _set_param(ctx: Ctx&, name: const u8[:], value: const u8[:]) -> bool {
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
fn _path_byte(s: const u8[:], i: i64) -> i64, i64 {
    if s[i] != '%' { return s[i], 1; }
    if i + 2 < s.len && ascii::hex_value(s[i + 1]) >= 0 && ascii::hex_value(s[i + 2]) >= 0 {
        return (ascii::hex_value(s[i + 1]) * 16 + ascii::hex_value(s[i + 2])), 3;
    }
    return -1, 0;
}

// True when every decoded byte is allowed: not / or \ or a control byte, and no segment decodes to . or ..
// Raw slashes separate segments.
fn _path_valid(s: const u8[:]) -> bool {
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
            let b, width = _path_byte(s, i);
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
    if !_path_valid(s) { return false; }
    var i = 0;
    while i < s.len {
        let b, width = _path_byte(s, i);
        out.push(b as u8);
        i += width;
    }
    return true;
}

// Called by the generated dispatcher. False, and the dispatcher answers 404, when the name or tail is over its
// limit, a segment is empty, or path_decode would refuse the tail; "" is a valid tail.
fn _set_rest(ctx: Ctx&, name: const u8[:], rest: const u8[:]) -> bool {
    if name.len > 32 || rest.len > 1024 { return false; }
    if rest.len > 0 {
        if rest[0] == '/' || rest[rest.len - 1] == '/' { return false; }
        for i in 1..rest.len {
            if rest[i] == '/' && rest[i - 1] == '/' { return false; }
        }
    }
    if !_path_valid(rest) { return false; }
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
fn _split(path: const u8[:], seg: const u8[:][16]&, starts: i64[16]&, ends: i64[16]&) -> i64 {
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

fn _all_in(s: const u8[:], set: const ByteSet&) -> bool {
    for c in s { if !set.members[c] { return false; } }
    return true;
}

// Appends v with %XX decoded; + stays +, and a bad escape stays as written.
fn _pct_decode(out: u8[>..]&, v: const u8[:]) {
    var i = 0;
    while i < v.len {
        if v[i] == '%' && i + 2 < v.len && ascii::hex_value(v[i + 1]) >= 0 && ascii::hex_value(v[i + 2]) >= 0 {
            out.push((ascii::hex_value(v[i + 1]) * 16 + ascii::hex_value(v[i + 2])) as u8);
            i += 3;
        } else { out.push(v[i]); i += 1; }
    }
}

// One rule: cookie, cookie_or and cookie_int percent-decode the value set_cookie encoded. cookie_raw does not.

// Appends the percent-decoded value to out; false when absent.
fn cookie(req: const http::Request&, name: const u8[:], out: u8[>..]&) -> bool {
    let v, has = http::cookie(req, name);
    if !has { return false; }
    _pct_decode(out, v);
    return true;
}

// The value exactly as the browser sent it (still encoded), and whether the cookie is present.
fn cookie_raw(req: const http::Request&, name: const u8[:]) -> const u8[:], bool {
    return http::cookie(req, name);
}

// The decoded value, or fallback when the cookie is absent or empty.
fn cookie_or(req: const http::Request&, name: const u8[:], fallback: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    if cookie(req, name, out) && out.len > 0 { return out; }
    out.clear();
    out.append(fallback);
    return out;
}

// The decoded value as a whole number; false when absent, empty or not a number.
fn cookie_int(req: const http::Request&, name: const u8[:]) -> i64, bool {
    var out: u8[>..] = [];
    if !cookie(req, name, out) || out.len == 0 { return 0, false; }
    return parse_int(out);
}

// The value is percent-encoded. False, with nothing set, when an argument or option is invalid,
// a __Secure- or __Host- name breaks its rule, or the response's cookies would pass 2048 bytes.
fn set_cookie(ctx: Ctx&, name: const u8[:], value: const u8[:], opts: CookieOptions = CookieOptions { .. }) -> bool {
    let secure = opts.secure || opts.same_site == SameSite.None;
    if name.len == 0 || name.len > COOKIE_NAME_MAX || !_all_in(name, COOKIE_NAME_BYTES) { return false; }
    if opts.path.len == 0 || opts.path[0] != '/' { return false; }
    for c in opts.path { if c <= ' ' || c >= 127 || c == ';' { return false; } }
    if !_all_in(opts.domain, COOKIE_DOMAIN_BYTES) || opts.max_age < -1 { return false; }
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
fn _apply_cookies(ctx: Ctx&, res: http::Response&) -> bool {
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

// ---------------------------------------------------------------- server-sent events (Addendum 12 section 7.9)

// Appends one SSE event: `event: E`, then each line of data as `data: LINE` (a line ends at \n, \r\n or \r, so
// data with a trailing newline ends in an empty data line and the browser joins it back), then a blank line.
// E must not contain a line break.
fn sse_event(out: u8[>..]&, event: const u8[:], data: const u8[:]) {
    out.append("event: ");
    out.append(event);
    out.append("\n");
    var start = 0;
    var i = 0;
    while i <= data.len {
        if i == data.len || data[i] == '\n' || data[i] == '\r' {
            out.append("data: ");
            out.append(data[start..i]);
            out.append("\n");
            if i < data.len && data[i] == '\r' && i + 1 < data.len && data[i + 1] == '\n' { i += 1; }
            start = i + 1;
        }
        i += 1;
    }
    out.append("\n");
}

// The `fragment` event: gwe.js morphs #name with html.
fn sse_fragment(out: u8[>..]&, name: const u8[:], html: const u8[:]) {
    var d: u8[>..] = [];
    d.append(name);
    d.append("\n");
    d.append(html);
    sse_event(out, "fragment", d);
}

// The `store` event: gwe.js writes the values json names into the store.
fn sse_store(out: u8[>..]&, store: const u8[:], json: const u8[:]) {
    var d: u8[>..] = [];
    d.append(store);
    d.append("\n");
    d.append(json);
    sse_event(out, "store", d);
}

// ---------------------------------------------------------------- responses

fn html(res: http::Response&, status: http::Status) {
    res.status = status;
    res.content_type.clear();
    res.content_type.append("text/html; charset=utf-8");
}

fn json(res: http::Response&, status: http::Status) { http::json_reply(res, status); }

fn not_found(ctx: Ctx&) { ctx.outcome = Outcome.NotFound; }

// A page handler that took `res` and wrote the whole reply (status, headers, body) calls this and returns: the
// generated code skips rendering and finish leaves res as written (DESIGN-ADDENDUM-14, D14).
fn done(ctx: Ctx&) { ctx.outcome = Outcome.Done; }

// The generated page function applies a nonzero status after rendering, while the outcome is Continue.
fn set_status(ctx: Ctx&, code: i64) { ctx.status = code; }

fn unprocessable(ctx: Ctx&) { ctx.status = 422; }

fn redirect(ctx: Ctx&, to: const u8[:], status: i64 = 302) {
    ctx.outcome = Outcome.Redirect;
    ctx.redirect_status = status;
    ctx.location.clear();
    ctx.location.append(to[..min(to.len, 1024)]);
}

fn _apply_redirect(ctx: const Ctx&, res: http::Response&) {
    res.status = http::status_from_code(ctx.redirect_status);
    res.content_type.clear();
    res.body.clear();
    http::set_header(res, "Location", ctx.location);
}

fn _options(res: http::Response&, allow: const u8[:]) {
    res.status = http::Status.NoContent;
    http::set_header(res, "Allow", allow);
}

fn _method_not_allowed(res: http::Response&, allow: const u8[:]) {
    http::json_error(res, http::Status.MethodNotAllowed, "method not allowed");
    http::set_header(res, "Allow", allow);
}

fn _plain_not_found(res: http::Response&) {
    http::text(res, http::Status.NotFound, "404 not found\n");
}

// The request's Content-Length: 0 when absent, -1 when malformed. Pages with MAX_UPLOAD compare it before reading the body.
fn _content_length(req: const http::Request&) -> i64 { return http::content_length(req.head); }

// ---------------------------------------------------------------- config

extern fn c_up_mkdir(path: const u8[:]) -> i32 = "gweb_up_mkdir";
extern fn c_up_sweep(dir: const u8[:]) -> i64 = "gweb_up_sweep";
extern fn c_up_unlink(path: const u8[:]) -> i32 = "gweb_up_unlink";

extern fn c_if_set_loop(slot: i64, handle: u64) = "gweb_inflight_set_loop";
extern fn c_if_begin(slot: i64, fd: i32, raw: const u8[:]) = "gweb_inflight_begin";
extern fn c_if_end(slot: i64) = "gweb_inflight_end";

extern fn c_performance_cores() -> i64 = "gweb_performance_cores";

// min(performance cores, 4); hardware threads where cores are unknown.
fn _default_workers() -> i64 {
    let perf = c_performance_cores();
    let cores = if perf > 0 { perf } else { hardware_threads() };
    return max(1, min(cores, 4));
}

fn _default_config() -> Config {
    Config { port: 3000, host: "0.0.0.0", workers: _default_workers(), log: false,
             idle_ms: 5000, max_body: 1048576, dev_id: 0,
             max_upload: 33554432, spool_over: 65536, upload_dir: ".gweb.uploads",
             auth: AuthConfig { .. }, security_headers: true, hsts: 0, csp: 0, export_dir: "",
             drain_ms: 10000, drain_delay_ms: 0, log_format: "text", log_level: "info",
             metrics: false, job_runners: 1, job_queue: 10000, job_attempts: 5, schedule: true, probe: false }
}

fn env_int(name: const u8[:]) -> i64, bool {
    var e: u8[>..] = [];
    if !env(name, e) { return 0, false; }
    return parse_int(trim(e));
}

fn _valid_log_level(s: const u8[:]) -> bool { s == "debug" || s == "info" || s == "warn" || s == "error" }

fn _valid_log_format(s: const u8[:]) -> bool { s == "text" || s == "json" }

// _config_from(args()), then --probe: GET http://127.0.0.1:PORT/__gweb/ready; exit 0 on 200, else 1.
fn _config_from_args() -> Config {
    let argv = args();
    var a: (const u8[:])[>..] = [];
    var i = 0;
    while i < argv.len { a.push(argv[i]); i += 1; }
    let cfg = _config_from(a);
    if cfg.probe { exit(_probe(cfg.port)); }
    return cfg;
}

fn _probe(port: i64) -> i64 {
    var url: u8[>..] = [];
    format(url, "http://127.0.0.1:", port, "/__gweb/ready");
    var body: u8[>..] = [];
    let status, ok = http::get(url, body);
    return if ok && http::code(status) == 200 { 0 } else { 1 };
}

// Reads the flags in the usage line below and the environment, after loading the .env files: PORT, GWEB_WORKERS,
// GWEB_SECRET, GWEB_SESSION_IDLE, GWEB_SESSION_MAX, GWEB_TRUST_PROXY, GWEB_SECURITY_HEADERS, GWEB_HSTS, GWEB_CSP,
// GWEB_DRAIN_MS, GWEB_DRAIN_DELAY_MS, GWEB_LOG_FORMAT, GWEB_LOG_LEVEL, GWEB_METRICS=1, GWEB_JOB_RUNNERS,
// GWEB_SCHEDULE=0 (flags win). a[0] is the program name. Exits with 2 on a bad flag, .env file, secret,
// session lifetime, GWEB_HSTS or GWEB_CSP.
fn _config_from(a: (const u8[:])[:]) -> Config {
    var cfg = _default_config();
    var envname: u8[>..] = [];
    var env_err: u8[>..] = [];
    var dev = false;
    for arg in a { if arg == "--dev-id" { dev = true; } }
    c_setenv("GWEB_ENV", if dev { "development" } else { "production" });
    _environment(envname);
    if !_load_env_files(envname, env_err) { print(env_err); exit(2); }
    var e: u8[>..] = [];
    if env("PORT", e) { let p, ok = parse_int(trim(e)); if ok { cfg.port = p; } }
    e.clear();
    if env("GWEB_WORKERS", e) { let w, ok = parse_int(trim(e)); if ok && w > 0 { cfg.workers = w; } }
    var csp_flag = false;
    let drain, has_drain = env_int("GWEB_DRAIN_MS");
    if has_drain && drain >= 0 { cfg.drain_ms = drain; }
    let delay, has_delay = env_int("GWEB_DRAIN_DELAY_MS");
    if has_delay && delay >= 0 { cfg.drain_delay_ms = delay; }
    let runners, has_runners = env_int("GWEB_JOB_RUNNERS");
    if has_runners && runners >= 0 { cfg.job_runners = runners; }
    e.clear();
    if env("GWEB_LOG_FORMAT", e) && _valid_log_format(trim(e)) { cfg.log_format.clear(); cfg.log_format.append(trim(e)); }
    e.clear();
    if env("GWEB_LOG_LEVEL", e) && _valid_log_level(trim(e)) { cfg.log_level.clear(); cfg.log_level.append(trim(e)); }
    e.clear();
    if env("GWEB_METRICS", e) && trim(e) == "1" { cfg.metrics = true; }
    e.clear();
    if env("GWEB_SCHEDULE", e) && trim(e) == "0" { cfg.schedule = false; }
    var i = 1;
    while i < a.len {
        let flag = a[i];
        let has_value = i + 1 < a.len;
        if flag == "--log" { cfg.log = true; i += 1; continue; }
        if flag == "--csp" { csp_flag = true; i += 1; continue; }
        if flag == "--metrics" { cfg.metrics = true; i += 1; continue; }
        if flag == "--no-schedule" { cfg.schedule = false; i += 1; continue; }
        if flag == "--probe" { cfg.probe = true; i += 1; continue; }
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
            if flag == "--export" && v.len > 0 && v.len <= 512 { cfg.export_dir.clear(); cfg.export_dir.append(v); i += 2; continue; }
            if flag == "--drain-ms" && ok && n >= 0 { cfg.drain_ms = n; i += 2; continue; }
            if flag == "--drain-delay-ms" && ok && n >= 0 { cfg.drain_delay_ms = n; i += 2; continue; }
            if flag == "--job-runners" && ok && n >= 0 { cfg.job_runners = n; i += 2; continue; }
            if flag == "--job-queue" && ok && n > 0 { cfg.job_queue = n; i += 2; continue; }
            if flag == "--job-attempts" && ok && n > 0 { cfg.job_attempts = n; i += 2; continue; }
            if flag == "--log-format" && _valid_log_format(v) { cfg.log_format.clear(); cfg.log_format.append(v); i += 2; continue; }
            if flag == "--log-level" && _valid_log_level(v) { cfg.log_level.clear(); cfg.log_level.append(v); i += 2; continue; }
            if flag == "--host" { cfg.host.clear(); cfg.host.append(v[..min(v.len, 64)]); i += 2; continue; }
        }
        print("unknown or incomplete flag: ", flag);
        print("flags: --port N --host H --workers N --log --idle-ms N --max-body N --max-upload N --upload-dir D --csp --export DIR --drain-ms N --drain-delay-ms N --log-format text|json --log-level debug|info|warn|error --metrics --no-schedule --job-runners N --job-queue N --job-attempts N --probe (--dev-id N: gweb dev only)");
        exit(2);
    }
    _old_env_names();
    var secret_err: u8[>..] = [];
    e.clear();
    if env("GWEB_SECRET", e) && trim(e).len > 0 {
        if !_parse_secret(e, cfg.auth.keys, secret_err) { print(secret_err); exit(2); }
    } else if cfg.dev_id != 0 {
        if !_dev_secret(cfg.auth.keys, secret_err) { print(secret_err); exit(2); }
    }
    cfg.auth.idle = _env_positive("GWEB_SESSION_IDLE", cfg.auth.idle);
    cfg.auth.max = _env_positive("GWEB_SESSION_MAX", cfg.auth.max);
    cfg.auth.trust_proxy = env_bool("GWEB_TRUST_PROXY", false);
    cfg.security_headers = env_bool("GWEB_SECURITY_HEADERS", true);
    cfg.hsts = _env_nonneg("GWEB_HSTS", 0);
    cfg.csp = _env_csp("GWEB_CSP");
    if csp_flag { cfg.csp = 1; }
    return cfg;
}

// ---------------------------------------------------------------- secrets and env (DESIGN-ADDENDUM-13)

// v0.5 renamed WEB_* to GWEB_*. An old name still set would be ignored, which could drop a secret or a CSP, so the
// server refuses to start and names the new one.
let OLD_ENV = ["WEB_SECRET", "WEB_CSP", "WEB_WORKERS", "WEB_TRUST_PROXY", "WEB_HSTS", "WEB_SESSION_IDLE",
               "WEB_SECURITY_HEADERS", "WEB_SESSION_MAX"];

fn _old_env_names() {
    var bad = false;
    for name in OLD_ENV {
        var v: u8[>..] = [];
        if env(name, v) { print("gweb: ", name, " is now G", name, "; rename it (in .env files too)"); bad = true; }
    }
    if bad { exit(2); }
}

// Fills buf from the OS; 1 on success, 0 when refused (more than 256 bytes).
extern fn c_entropy(buf: u8[:]) -> i32 = "gweb_entropy";

let B64URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

let HEX_LOWER = "0123456789abcdef";

// base64url without padding, appended to out.
fn b64url(out: u8[>..]&, data: const u8[:]) {
    var i = 0;
    while i + 2 < data.len {
        let n = ((data[i] as i64) << 16) | ((data[i + 1] as i64) << 8) | data[i + 2];
        out.push(B64URL[(n >> 18) & 63]);
        out.push(B64URL[(n >> 12) & 63]);
        out.push(B64URL[(n >> 6) & 63]);
        out.push(B64URL[n & 63]);
        i += 3;
    }
    let rest = data.len - i;
    if rest == 1 {
        let n = (data[i] as i64) << 16;
        out.push(B64URL[(n >> 18) & 63]);
        out.push(B64URL[(n >> 12) & 63]);
    } else if rest == 2 {
        let n = ((data[i] as i64) << 16) | ((data[i + 1] as i64) << 8);
        out.push(B64URL[(n >> 18) & 63]);
        out.push(B64URL[(n >> 12) & 63]);
        out.push(B64URL[(n >> 6) & 63]);
    }
}

// ---- env files and typed env

extern fn c_setenv(name: const u8[:], value: const u8[:]) -> i32 = "gweb_setenv";

// Appends GWEB_ENV, or "production" when it is unset or empty.
fn _environment(out: u8[>..]&) {
    let before = out.len;
    env("GWEB_ENV", out);
    if out.len == before { out.append("production"); }
}

fn env_str(name: const u8[:], out: u8[>..]&) -> bool { return env(name, out); }

fn env_int(name: const u8[:], fallback: i64) -> i64 {
    var e: u8[>..] = [];
    if !env(name, e) { return fallback; }
    let n, ok = parse_int(trim(e));
    if ok { return n; }
    return fallback;
}

fn _lower_is(s: const u8[:], word: const u8[:]) -> bool {
    if s.len != word.len { return false; }
    for i in s.len {
        var c = s[i];
        if c >= 'A' && c <= 'Z' { c = c + 32; }
        if c != word[i] { return false; }
    }
    return true;
}

// 1/true/yes/on and 0/false/no/off, case-insensitive; fallback when unset or anything else.
fn env_bool(name: const u8[:], fallback: bool) -> bool {
    var e: u8[>..] = [];
    if !env(name, e) { return fallback; }
    let t = trim(e);
    for w in ["1", "true", "yes", "on"] { if _lower_is(t, w) { return true; } }
    for w in ["0", "false", "no", "off"] { if _lower_is(t, w) { return false; } }
    return fallback;
}

fn env_required(name: const u8[:]) -> bool {
    var e: u8[>..] = [];
    if env(name, e) { return true; }
    var msg: u8[>..] = [];
    format(msg, "config: ", name, " is not set\n");
    write_stderr(msg);
    return false;
}

// Only a positive integer replaces fallback; a bad lifetime is a startup error, not a silent default.
fn _env_positive(name: const u8[:], fallback: i64) -> i64 {
    var e: u8[>..] = [];
    if !env(name, e) || trim(e).len == 0 { return fallback; }
    let n, ok = parse_int(trim(e));
    if ok && n > 0 { return n; }
    print(name, " must be a positive whole number of seconds");
    exit(2);
    return fallback;
}

// Like env_positive, but 0 is allowed.
fn _env_nonneg(name: const u8[:], fallback: i64) -> i64 {
    var e: u8[>..] = [];
    if !env(name, e) || trim(e).len == 0 { return fallback; }
    let n, ok = parse_int(trim(e));
    if ok && n >= 0 { return n; }
    print(name, " must be a whole number of seconds, 0 or more");
    exit(2);
    return fallback;
}

// 1 for 1/true/yes/on, 2 for report-only, 0 for unset, empty or 0/false/no/off; anything else is a startup error.
fn _env_csp(name: const u8[:]) -> i64 {
    var e: u8[>..] = [];
    if !env(name, e) || trim(e).len == 0 { return 0; }
    let t = trim(e);
    if _lower_is(t, "report-only") { return 2; }
    for w in ["1", "true", "yes", "on"] { if _lower_is(t, w) { return 1; } }
    for w in ["0", "false", "no", "off"] { if _lower_is(t, w) { return 0; } }
    print(name, " must be 1, 0 or report-only");
    exit(2);
    return 0;
}

fn _env_name_start(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
fn _env_name_byte(c: u8) -> bool { return _env_name_start(c) || (c >= '0' && c <= '9'); }

// One .env line: 0 skipped (blank or comment), 1 a pair (name and value appended), -1 malformed.
// An optional "export " prefix; the value is trimmed and one pair of matching quotes removed; # inside a value is kept.
fn _parse_env_line(line: const u8[:], name: u8[>..]&, value: u8[>..]&) -> i64 {
    let t = trim(line);
    if t.len == 0 || t[0] == '#' { return 0; }
    var i = 0;
    if starts_with(t, "export ") {
        i = 7;
        while i < t.len && t[i] == ' ' { i += 1; }
    }
    let start = i;
    while i < t.len && _env_name_byte(t[i]) { i += 1; }
    if i == start || !_env_name_start(t[start]) || i >= t.len || t[i] != '=' { return -1; }
    let v = trim(t[i + 1..]);
    name.append(t[start..i]);
    if v.len >= 2 && (v[0] == '"' || v[0] == '\'') && v[v.len - 1] == v[0] {
        value.append(v[1..v.len - 1]);
    } else {
        value.append(v);
    }
    return 1;
}

// std::split, which gweb::_split (the path splitter) shadows in this namespace.
fn _split_on(s: const u8[:], sep: u8) -> const u8[:][>..] {
    var out: const u8[:][>..] = [];
    var start = 0;
    for c, i in s {
        if c == sep { out.push(s[start..i]); start = i + 1; }
    }
    out.push(s[start..]);
    return out;
}

// Sets every pair in the file that is not already set, so the real environment and earlier files win.
// A missing file is skipped. False, with err set to "path:N: error: ...", on a malformed line.
fn _load_env_file(path: const u8[:], err: u8[>..]&) -> bool {
    var text: u8[>..] = [];
    if !read_file(path, text) { return true; }
    for line, i in _split_on(text, '\n') {
        var name: u8[>..] = [];
        var value: u8[>..] = [];
        let r = _parse_env_line(line, name, value);
        if r < 0 {
            format(err, path, ":", i + 1, ": error: expected NAME=value");
            return false;
        }
        if r == 1 && c_setenv(name, value) == 0 {
            format(err, path, ":", i + 1, ": error: cannot set ", name);
            return false;
        }
    }
    return true;
}

// dir is "" for the working directory, else a folder path without a trailing slash.
fn _load_env_files_in(dir: const u8[:], envname: const u8[:], err: u8[>..]&) -> bool {
    if envname.len == 0 || envname.len > 32 { format(err, "GWEB_ENV: invalid name"); return false; }
    for c in envname {
        if !_env_name_byte(c) && c != '-' { format(err, "GWEB_ENV: invalid name"); return false; }
    }
    for k in 4 {
        if k == 1 && envname == "test" { continue; }   // tests must not depend on a developer's local overrides
        var path: u8[>..] = [];
        if dir.len > 0 { format(path, dir, "/"); }
        if k == 0 { format(path, ".env.", envname, ".local"); }
        else if k == 1 { path.append(".env.local"); }
        else if k == 2 { format(path, ".env.", envname); }
        else { path.append(".env"); }
        if !_load_env_file(path, err) { return false; }
    }
    return true;
}

// Order: .env.<env>.local, .env.local (not for test), .env.<env>, .env; the first to set a name wins.
fn _load_env_files(envname: const u8[:], err: u8[>..]&) -> bool {
    return _load_env_files_in("", envname, err);
}

// ---- secrets

// Parses GWEB_SECRET: 1 to 4 comma-separated keys of 32 to 64 bytes. False, with err set, otherwise; err never holds key bytes.
fn _parse_secret(text: const u8[:], keys: Keys&, err: u8[>..]&) -> bool {
    keys.n = 0;
    for item, i in _split_on(trim(text), ',') {
        let k = trim(item);
        if i >= 4 { format(err, "GWEB_SECRET: more than 4 keys"); keys.n = 0; return false; }
        if k.len == 0 { format(err, "GWEB_SECRET: key ", i + 1, " is empty"); keys.n = 0; return false; }
        if k.len < 32 { format(err, "GWEB_SECRET: key ", i + 1, " is shorter than 32 bytes"); keys.n = 0; return false; }
        if k.len > 64 { format(err, "GWEB_SECRET: key ", i + 1, " is longer than 64 bytes"); keys.n = 0; return false; }
        keys.k[i].clear();
        keys.k[i].append(k);
        keys.n = i + 1;
    }
    return keys.n > 0;
}

// gweb dev only: a stable key in .gweb.dev/secret keeps sessions alive across rebuilds. 32 random bytes as 64 hex digits.
fn _dev_secret(keys: Keys&, err: u8[>..]&) -> bool {
    var text: u8[>..] = [];
    var ignored: u8[>..] = [];
    if read_file(".gweb.dev/secret", text) && _parse_secret(text, keys, ignored) { return true; }
    var raw: u8[..32] = [0; 32];
    if c_entropy(raw) == 0 { format(err, "gweb: cannot read system entropy for the dev secret"); return false; }
    var hex: u8[>..] = [];
    for b in raw {
        hex.push(HEX_LOWER[(b >> 4) as i64]);
        hex.push(HEX_LOWER[(b & 15) as i64]);
    }
    make_dir(".gweb.dev");
    write_file(".gweb.dev/secret", hex);   // a write failure only costs session persistence across restarts
    return _parse_secret(hex, keys, err);
}

// ---- security headers and CSP (DESIGN-ADDENDUM-13)

// 16 random bytes as 22 b64url bytes in ctx.nonce; true without change when already set. False when entropy fails.
fn _make_nonce(ctx: Ctx&) -> bool {
    if ctx.nonce.len > 0 { return true; }
    var raw: u8[..16] = [0; 16];
    if c_entropy(raw) == 0 { return false; }
    var enc: u8[>..] = [];
    b64url(enc, raw);
    ctx.nonce.append(enc);
    return true;
}

// For a subtree's `before`: turns the CSP on for this request even when GWEB_CSP is off.
fn csp_begin(ctx: Ctx&) -> bool { return _make_nonce(ctx); }

// Appends the default security headers, HSTS and CSP; false, with a bare 500, when they do not fit beside res.headers.
fn _apply_security(ctx: Ctx&, res: http::Response&, cfg: const Config&) -> bool {
    var hdrs: u8[>..] = [];
    if cfg.security_headers && ctx.default_headers {
        hdrs.append("X-Content-Type-Options: nosniff\r\n");
        hdrs.append("Referrer-Policy: strict-origin-when-cross-origin\r\n");
        hdrs.append("X-Frame-Options: SAMEORIGIN\r\n");
    }
    if cfg.hsts > 0 { format(hdrs, "Strict-Transport-Security: max-age=", cfg.hsts, "; includeSubDomains\r\n"); }
    if ctx.nonce.len > 0 && starts_with(res.content_type, "text/html") {
        // csp_begin with GWEB_CSP off asks for enforcement.
        hdrs.append(if cfg.csp == 2 { "Content-Security-Policy-Report-Only: " } else { "Content-Security-Policy: " });
        format(hdrs, "script-src 'self' 'nonce-", ctx.nonce, "'; object-src 'none'; base-uri 'self'; frame-ancestors 'self'\r\n");
    }
    if hdrs.len > res.headers.cap - res.headers.len {
        res.headers.clear();
        http::json_error(res, http::Status.InternalServerError, "response headers too large");
        return false;
    }
    res.headers.append(hdrs);
    return true;
}

// ---------------------------------------------------------------- the worker loop

// One parsed request through the framework. Returns the static file index to send (or -1), and true when the
// request was answered here (gweb dev's status, health, readiness, metrics): not logged and not counted.
fn _respond<D>(req: const http::Request&, ctx: Ctx&, conn_fd: i32, cfg: const Config&, res: http::Response&) -> i64, bool {
    let p = req.path;
    let get_like = req.method == http::Method.Get || req.method == http::Method.Head;
    if cfg.dev_id != 0 && p == "/__gweb/id" {
        _dev_status(res, cfg.dev_id);
        return -1, true;
    }
    if get_like && p == "/__gweb/health" {
        http::text(res, http::Status.Ok, "ok\n");
        http::set_header(res, "Cache-Control", "no-store");
        return -1, true;
    }
    if get_like && p == "/__gweb/ready" {
        if net::stopping() { http::text(res, http::Status.ServiceUnavailable, "stopping\n"); }
        else { http::text(res, http::Status.Ok, "ready\n"); }
        http::set_header(res, "Cache-Control", "no-store");
        return -1, true;
    }
    if get_like && cfg.metrics && p == "/__gweb/metrics" {
        http::text(res, http::Status.Ok, "");
        res.content_type.clear();
        res.content_type.append("text/plain; version=0.0.4; charset=utf-8");
        c_metrics_render(res.body, trim(WEB_VERSION));
        http::set_header(res, "Cache-Control", "no-store");
        return -1, true;
    }
    let tracing = c_otel_on() != 0;
    if cfg.log || tracing { _begin_request(req, ctx, tracing); }
    if get_like && p.len > 1 && p[p.len - 1] == '/' {
        var to: u8[>..] = [];
        to.append(p[..p.len - 1]);
        if req.query.len > 0 { to.push('?'); to.append(req.query); }
        res.status = http::Status.PermanentRedirect;
        http::set_header(res, "Location", to);
        return -1, false;
    }
    ctx.auth = cfg.auth;
    ctx.conn_fd = conn_fd;
    if cfg.csp != 0 && !_make_nonce(ctx) {
        http::json_error(res, http::Status.InternalServerError, "csp nonce unavailable");
        return -1, false;
    }
    var static_index = D(req, ctx, res);
    if !_apply_cookies(ctx, res) { static_index = -1; ctx.detach = Detach.None; }
    if !ctx.streamed && !_apply_security(ctx, res, cfg) { static_index = -1; ctx.detach = Detach.None; }
    if !ctx.fragment { _dev_inject(res, cfg.dev_id, ctx.nonce); }
    return static_index, false;
}

// D, the generated dispatcher, returns the index of a static file to send, or -1; S gives its bytes, sent without a copy.
// routes is the route patterns joined by newlines, in the order of the indexes D puts in ctx.route_label; it names the
// route in the access log and in spans. Returns when the process is stopping and this worker has drained.
fn _run_worker<D, S>(slot: i64, server: net::Socket, owner_fd: i32, cfg: Config, routes: const u8[:] = "") {
    // One worker takes every waiting connection per pass; several take one each, so a burst spreads.
    let lp = net::connection_loop(server, cfg.idle_ms, cfg.max_body, if cfg.workers == 1 { 0 } else { 1 });
    // Uploads: make the directory, then opt in. main() calls gweb::_prepare_uploads once first, which deletes files an earlier run left (names gnet-* and gw-*).
    // Without a usable directory a multipart body stays in memory, up to --max-body.
    if cfg.upload_dir.len > 0 && c_up_mkdir(cfg.upload_dir) != 0 {
        if !lp.set_uploads(cfg.max_upload, cfg.spool_over, cfg.upload_dir) {
            print("warning: cannot use upload dir ", cfg.upload_dir, "; uploads are limited to --max-body");
        }
    } else {
        print("warning: cannot create upload dir ", cfg.upload_dir, "; uploads are limited to --max-body");
    }
    // D12: the supervisor frees this loop, and answers the request in flight, if the worker aborts.
    c_if_set_loop(slot, lp.handle);
    let tracing = c_otel_on() != 0;
    let json_log = cfg.log_format == "json";
    let timed = cfg.log || cfg.metrics || tracing;
    var raw: u8[>..] = [];
    loop {
        raw.clear();
        let conn, ev = lp.next(raw);
        if cfg.metrics { c_metrics_conn(slot as i32, lp.open_connections()); }
        var res = http::new_response();
        match ev {
            Request, Spooled => {
                let t0 = if timed { c_now_us() } else { 0 };
                var ctx = _new_ctx(slot, owner_fd, cfg.hub);
                ctx.start_us = t0;
                ctx.upload_dir.append(cfg.upload_dir);
                var spool_ok = true;
                if ev == net::Event.Spooled {
                    var sp: u8[>..] = [];
                    lp.spool_path(sp);
                    if sp.len > ctx.spool.cap { c_up_unlink(sp); spool_ok = false; } else { ctx.spool.append(sp); }
                }
                let req, parsed = http::parse_request(raw);
                c_if_begin(slot, conn.fd, raw);
                var keep = false;
                var static_index = -1;
                var internal = false;   // answered by respond itself: not logged, not counted
                match parsed {
                    Ready => {
                        keep = http::wants_keep_alive(req);
                        if !spool_ok {
                            http::json_error(res, http::Status.InternalServerError, http::reason(http::Status.InternalServerError));
                        } else {
                            let index, here = _respond(req, ctx, conn.fd, cfg, res, D);
                            static_index = index;
                            internal = here;
                        }
                    },
                    Reject r => http::json_error(res, r.status, http::reason(r.status)),
                    Closed => {},
                }
                keep = keep && !net::draining();
                if ctx.request_id.len > 0 && !ctx.streamed { http::add_header(res, "X-Request-Id", ctx.request_id); }
                let head_only = req.method == http::Method.Head;
                var label: const u8[:] = if static_index >= 0 { "static" } else { _route_name(routes, ctx.route_label) };
                var blen = 0;
                if ctx.streamed {
                    // A stream wrote its own reply; the connection survives only if its body was framed (chunked), ended, and keep-alive was asked for.
                    if !(keep && ctx.stream_ended && http::supports_chunked(req)) { lp.close_connection(conn); }
                } else if ctx.detach != Detach.None {
                    // The hub owns the socket after the head is out; a failed head or a full hub closes it.
                    var rest: u8[>..] = [];
                    let kind = if ctx.detach == Detach.Stream { net::HubKind.Stream } else { net::HubKind.WebSocket };
                    let head_ok = if ctx.detach == Detach.Stream { http::begin_chunked(conn, res, false, false, true) }
                                  else { http::send_head(conn, res, "Upgrade") };
                    if head_ok {
                        lp.detach(conn, rest);
                        net::add(net::Hub { handle: cfg.hub }, conn, kind, ctx.topic, rest, ctx.heartbeat);
                    } else { lp.close_connection(conn); }
                    label = if ctx.detach == Detach.Stream { "stream" } else { "websocket" };
                } else {
                    let sent = if static_index >= 0 {
                        http::send_response_with(conn, res, S(static_index), head_only, keep)
                    } else {
                        http::send_response(conn, res, head_only, keep)
                    };
                    blen = if static_index >= 0 { S(static_index).len } else { res.body.len };
                    if !sent || !keep { lp.close_connection(conn); }
                }
                if !internal && (cfg.log || cfg.metrics || ctx.sampled) {
                    let dur = c_now_us() - t0;
                    if cfg.metrics {
                        let route_index = if static_index >= 0 { -2 } else { ctx.route_label };
                        c_metrics_request(slot as i32, route_index as i32, _method_index(req.method) as i32,
                                          http::code(res.status) as i32, dur);
                    }
                    if cfg.log {
                        var line: u8[>..] = [];
                        _access_line(line, json_log, slot, req.method_text, req.target, label, res.status, dur, blen,
                                    ctx.request_id, ctx.trace_id, ctx.span_id);
                        _log_write(Level.Info, line);
                    }
                    if ctx.sampled { _push_server_span(ctx, req, label, res.status, dur); }
                }
                c_if_end(slot);
                // The reply is out: delete the spool file and every upload not saved (a saved one is gone, so its unlink fails harmlessly).
                if ctx.spool.len > 0 { c_up_unlink(ctx.spool); }
                for i in ctx.uploads.len {
                    if ctx.uploads[i].path.len > 0 { c_up_unlink(ctx.uploads[i].path); }
                }
            },
            Stopped => { lp.free(); return; },
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
fn _dev_status(res: http::Response&, dev_id: i64) {
    http::text(res, http::Status.Ok, "");
    format(res.body, dev_id);
    var errs: u8[>..] = [];
    var warns: u8[>..] = [];
    res.body.push('\n');
    if read_file(".gweb.dev/errors.txt", errs) && errs.len > 0 { res.body.append(errs); }
    if read_file(".gweb.dev/warnings.txt", warns) && warns.len > 0 {
        res.body.append("\x0c");
        res.body.append(warns);
    }
    http::set_header(res, "Cache-Control", "no-store");
}

// Appends the dev script that polls /__gweb/id: reload on a new id, error overlay otherwise.
// The poll body is `id\n` + errors, then `\f` + warnings when there are any. Warnings show in a small
// box at the bottom right, dismissed by a click and shown again only when their text changes.
// Two overlay slots: sys (build failed or server down; the poll sets and clears it) and isl
// (page errors; cleared by a click or reload). sys shows first.
fn _dev_inject(res: http::Response&, dev_id: i64, nonce: const u8[:]) {
    if dev_id == 0 || !starts_with(res.content_type, "text/html") { return; }
    if nonce.len > 0 { format(res.body, "<script nonce=\"", nonce, "\">"); } else { res.body.append("<script>"); }
    format(res.body, "(function(){var id=\"", dev_id, "\",fails=0,box,sys=\"\",isl=\"\",wbox,wtxt=\"\",wdis=\"\";\n");
    res.body.append("""function draw(){var t=sys||isl;if(!t){if(box){box.remove();box=null}return}""");
    res.body.push('\n');
    res.body.append("""if(!box){box=document.createElement("pre");box.style.cssText="position:fixed;inset:0;margin:0;padding:24px;background:rgba(20,0,0,.92);color:#fff;font:13px/1.5 monospace;white-space:pre-wrap;overflow:auto;z-index:2147483647";box.onclick=function(){isl="";draw()};document.body.appendChild(box)}""");
    res.body.push('\n');
    res.body.append("""if(box.textContent!==t)box.textContent=t}""");
    res.body.push('\n');
    res.body.append("""function wdraw(w){w=w.trim();if(!w){wdis="";if(wbox){wbox.remove();wbox=null}return}if(w===wdis)return;if(!wbox){wbox=document.createElement("pre");wbox.style.cssText="position:fixed;right:12px;bottom:12px;max-width:50vw;max-height:30vh;overflow:auto;margin:0;padding:8px 12px;background:rgba(60,45,0,.95);color:#fff;font:12px monospace;white-space:pre-wrap;cursor:pointer;z-index:2147483646";wbox.onclick=function(){wdis=wtxt;wbox.remove();wbox=null};document.body.appendChild(wbox)}wtxt=w;if(wbox.textContent!==w)wbox.textContent=w}""");
    res.body.push('\n');
    res.body.append("""addEventListener("gw:error",function(e){isl+=(isl?"\n":"page error (click to dismiss)\n\n")+e.detail;draw()});""");
    res.body.push('\n');
    // A server error page carries its detail (errors.goose, D13) in <script type="application/json" id="gw-dev-error">.
    res.body.append("""addEventListener("load",function(){var s=document.getElementById("gw-dev-error");if(s){try{isl="server error (click to dismiss)\n\n"+JSON.parse(s.textContent)}catch(x){}draw()}});""");
    res.body.push('\n');
    res.body.append("""setInterval(function(){fetch("/__gweb/id",{cache:"no-store"}).then(function(r){return r.text()}).then(function(t){fails=0;var n=t.indexOf("\n"),cur=n<0?t:t.slice(0,n),rest=n<0?"":t.slice(n+1),f=rest.indexOf("\f"),errs=f<0?rest:rest.slice(0,f),warns=f<0?"":rest.slice(f+1);if(cur!==id){location.reload();return}sys=errs.trim()?"build failed\n\n"+errs:"";draw();wdraw(warns)}).catch(function(){if(++fails>=4){sys="gweb dev: the server is not responding";draw()}})},500)})();</script>""");
}

fn _no_static(i: i64) -> const u8[:] { "" }

// ---------------------------------------------------------------- operations
// Logging, metrics and tracing helpers that run_worker needs; ops.goose and jobs.goose build the app API on them.

let WEB_VERSION = embed_file("VERSION");

extern fn c_now_us() -> i64 = "gweb_now_us";
extern fn c_rfc3339(out: u8[>..]&) = "gweb_rfc3339";
extern fn c_rand_hex(out: u8[>..]&, nbytes: i32) = "gweb_rand_hex";
extern fn c_log_line(line: const u8[:]) = "gweb_log_line";
extern fn c_log_config(level: i32, json: i32) = "gweb_log_config";
extern fn c_log_level() -> i32 = "gweb_log_level";
extern fn c_log_json() -> i32 = "gweb_log_json";
extern fn c_metrics_init(workers: i32, route_names_nl: const u8[:]) = "gweb_metrics_init";
extern fn c_metrics_request(worker: i32, route: i32, method: i32, status: i32, dur_us: i64) = "gweb_metrics_request";
extern fn c_metrics_conn(worker: i32, open_count: i64) = "gweb_metrics_conn";
extern fn c_metric_count(name: const u8[:], n: i64) = "gweb_metric_count";
extern fn c_metric_gauge(name: const u8[:], v: f64) = "gweb_metric_gauge";
extern fn c_metrics_render(out: u8[>..]&, version: const u8[:]) = "gweb_metrics_render";

extern fn c_unix_ns() -> i64 = "gweb_unix_ns";
extern fn c_trace_parse(header: const u8[:], trace_out: u8[>..]&, parent_out: u8[>..]&, sampled: i32&) -> i32 = "gweb_trace_parse";
extern fn c_otel_sample(parent_sampled: i32, trace_id: const u8[:]) -> i32 = "gweb_otel_sample";
extern fn c_traceparent(out: u8[>..]&, trace: const u8[:], span: const u8[:], sampled: i32) = "gweb_traceparent";
extern fn c_span_push(trace: const u8[:], span: const u8[:], parent: const u8[:], name: const u8[:], kind: i32,
                      start_ns: i64, end_ns: i64, status: i32, method: const u8[:], route: const u8[:],
                      path: const u8[:], http_status: i32, attr_key: const u8[:], attr_val: const u8[:],
                      attr_is_int: i32) -> i32 = "gweb_span_push";
extern fn c_otel_start_from_env() -> i32 = "gweb_otel_start_from_env";
extern fn c_otel_on() -> i32 = "gweb_otel_on";
extern fn c_otel_flush(timeout_ms: i32) -> i32 = "gweb_otel_flush";

fn _level_name(l: Level) -> const u8[:] {
    match l { Debug => "debug", Info => "info", Warn => "warn", Error => "error" }
}

fn _level_num(l: Level) -> i64 {
    match l { Debug => 0, Info => 1, Warn => 2, Error => 3 }
}

// "info" for anything that is not a level name.
fn _level_from_name(s: const u8[:]) -> Level {
    if s == "debug" { return Level.Debug; }
    if s == "warn" { return Level.Warn; }
    if s == "error" { return Level.Error; }
    return Level.Info;
}

// Sets the level and format every log_write and log_message uses (process-wide, in C).
fn _log_configure(level: Level, json: bool) {
    c_log_config(_level_num(level) as i32, if json { 1 } else { 0 });
}

// Writes one finished line (no newline needed) when level is at or above the configured one.
fn _log_write(level: Level, line: const u8[:]) {
    let floor = c_log_level() as i64;
    if _level_num(level) < floor { return; }
    c_log_line(line);
}

// A framework message: the text as it is in text format, {"ts","level","msg"} in json format.
fn _log_message(level: Level, msg: const u8[:]) {
    var line: u8[>..] = [];
    if c_log_json() != 0 {
        line.append("{\"ts\":\"");
        c_rfc3339(line);
        format(line, "\",\"level\":\"", _level_name(level), "\",\"msg\":\"");
        json_escape(line, msg);
        line.append("\"}");
    } else {
        line.append(msg);
    }
    _log_write(level, line);
}

// The bytes of one JSON string body: " and \ with a backslash, bytes below 0x20 as \u00XX, the rest as they are.
fn _json_escape_byte(out: u8[>..]&, c: u8) {
    if c == 34 { out.append("\\\""); }
    else if c == '\\' { out.append("\\\\"); }
    else if c < 32 {
        out.append("\\u00");
        out.push(HEX_UPPER[c >> 4]);
        out.push(HEX_UPPER[c & 15]);
    }
    else { out.push(c); }
}

// Appends s, escaped for the inside of a JSON string (no quotes).
fn json_escape(out: u8[>..]&, s: const u8[:]) {
    for c in s { _json_escape_byte(out, c); }
}

// Like json_escape, but stops before the byte that would take out past max bytes; false when it stopped.
fn _json_escape_max(out: u8[>..]&, s: const u8[:], max: i64) -> bool {
    for c in s {
        let width = if c == 34 || c == '\\' { 2 } else if c < 32 { 6 } else { 1 };
        if out.len + width > max { return false; }
        _json_escape_byte(out, c);
    }
    return true;
}

// 1 to 64 bytes of [A-Za-z0-9._-]: what run_worker accepts as the request's X-Request-Id.
fn _request_id_valid(s: const u8[:]) -> bool {
    if s.len < 1 || s.len > 64 { return false; }
    for c in s {
        let ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        if !ok { return false; }
    }
    return true;
}

// The order of http::Method, which the metrics table indexes by.
fn _method_index(m: http::Method) -> i64 {
    match m { Get => 0, Head => 1, Post => 2, Put => 3, Patch => 4, Delete => 5, Options => 6, Other => 7 }
}

// Line i of routes (patterns joined by newlines); "" when there is none.
fn _route_name(routes: const u8[:], i: i64) -> const u8[:] {
    if i < 0 { return ""; }
    var n = 0;
    var start = 0;
    for k in 0..routes.len + 1 {
        if k == routes.len || routes[k] == '\n' {
            if n == i { return routes[start..k]; }
            n += 1;
            start = k + 1;
        }
    }
    return "";
}

// Takes X-Request-Id when it is valid, else makes 16 hex digits. With tracing: reads traceparent (a new trace
// id when it is missing or invalid), makes this request's span id and decides whether it is sampled.
fn _begin_request(req: const http::Request&, ctx: Ctx&, tracing: bool) {
    let sent, has = http::header(req, "x-request-id");
    if has && _request_id_valid(trim(sent)) {
        ctx.request_id.append(trim(sent));
    } else {
        var id: u8[>..] = [];
        c_rand_hex(id, 8);
        ctx.request_id.append(id);
    }
    if !tracing { return; }
    var trace: u8[>..] = [];
    var parent: u8[>..] = [];
    var parent_sampled: i32 = -1;
    var flag: i32 = 0;
    let tp, has_tp = http::header(req, "traceparent");
    if has_tp && c_trace_parse(trim(tp), trace, parent, flag) != 0 {
        parent_sampled = flag;
    } else {
        trace.clear();
        parent.clear();
        c_rand_hex(trace, 16);
    }
    var sid: u8[>..] = [];
    c_rand_hex(sid, 8);
    ctx.trace_id.append(trace);
    ctx.parent_span.append(parent);
    ctx.span_id.append(sid);
    ctx.sampled = c_otel_sample(parent_sampled, trace) != 0;
}

fn _push_server_span(ctx: const Ctx&, req: const http::Request&, route: const u8[:], status: http::Status, dur_us: i64) {
    var name: u8[>..] = [];
    name.append(req.method_text);
    if route.len > 0 { name.push(' '); name.append(route); }
    let end_ns = c_unix_ns();
    let code = http::code(status);
    let kind_status: i32 = if code >= 500 { 2 } else { 0 };
    c_span_push(ctx.trace_id, ctx.span_id, ctx.parent_span, name, 2, end_ns - dur_us * 1000, end_ns, kind_status,
                req.method_text, route, req.path, code as i32, "", "", 0);
}

// Appends one access line. Text: [slot] METHOD target -> 200 OK 42us. Json: one object with ts, level, msg "request",
// method, target, route ("-" when none), status, dur_us, bytes, worker, and request_id, trace_id and span_id when set.
fn _access_line(out: u8[>..]&, json: bool, slot: i64, method: const u8[:], target: const u8[:], route: const u8[:],
               status: http::Status, dur_us: i64, bytes: i64, request_id: const u8[:], trace_id: const u8[:],
               span_id: const u8[:]) {
    if !json {
        format(out, "[", slot, "] ", method, " ", target, " -> ", status, " ", dur_us, "us");
        return;
    }
    out.append("{\"ts\":\"");
    c_rfc3339(out);
    out.append("\",\"level\":\"info\",\"msg\":\"request\",\"method\":\"");
    json_escape(out, method);
    out.append("\",\"target\":\"");
    json_escape(out, target);
    out.append("\",\"route\":\"");
    json_escape(out, if route.len > 0 { route } else { "-" });
    format(out, "\",\"status\":", http::code(status), ",\"dur_us\":", dur_us, ",\"bytes\":", bytes, ",\"worker\":", slot);
    if request_id.len > 0 { out.append(",\"request_id\":\""); json_escape(out, request_id); out.append("\""); }
    if trace_id.len > 0 {
        out.append(",\"trace_id\":\"");
        json_escape(out, trace_id);
        out.append("\",\"span_id\":\"");
        json_escape(out, span_id);
        out.append("\"");
    }
    out.append("}");
}
