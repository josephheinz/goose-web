// web: the runtime of goose-web, a Next.js-like framework on goose-net.
// `gweb` generates the root file whose dispatcher calls the user's routes, pages and middleware.

namespace web;

import std;
import os;
import net;   // the root file declares it: import net from "OWNER/goose-net@<tag>";
import net.http;
import net.lifecycle;
import json;

// ---------------------------------------------------------------- types

struct Params { n: i64, names: u8[..32][8], values: u8[..256][8],
                rest_name: u8[..32] = "", rest: u8[..1024] = "" }   // the catch-all tail has its own, larger field

enum Outcome { Continue, NotFound, Redirect }

enum Level { Debug, Info, Warn, Error }

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
    route: i64 = -1,          // the dispatcher sets the route's index (its position in ROUTES) before it calls the handler
    request_id: u8[..64] = "",    // set when the access log or tracing is on
    trace_id: u8[..32] = "",      // set when tracing is on; sampled or not
    span_id: u8[..16] = "",       // the current span: the request's, or the innermost open web::span
    parent_span: u8[..16] = "",   // the caller's span from a traceparent header
    sampled: bool = false,
    start_us: i64 = 0,            // monotonic; 0 when nothing needed the time
    job_id: i64 = 0,              // set in a job runner's ctx
    attempt: i64 = 0
}

struct Config { port: i64, host: u8[..64], workers: i64, log: bool, idle_ms: i64, max_body: i64,
                dev_id: i64,            // 0 = off
                drain_ms: i64, drain_delay_ms: i64,
                log_format: u8[..8], log_level: u8[..8],   // "text" or "json"; "debug", "info", "warn" or "error"
                metrics: bool, job_runners: i64, job_queue: i64, job_attempts: i64,
                schedule: bool,         // false: jobs run, but no schedule fires
                probe: bool }           // --probe: config_from_args answers it and exits

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

// ---------------------------------------------------------------- config

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
             drain_ms: 10000, drain_delay_ms: 0, log_format: "text", log_level: "info",
             metrics: false, job_runners: 1, job_queue: 10000, job_attempts: 5, schedule: true, probe: false }
}

fn env_int(name: const u8[:]) -> i64, bool {
    var e: u8[>..] = [];
    if !env(name, e) { return 0, false; }
    return parse_int(trim(e));
}

fn valid_log_level(s: const u8[:]) -> bool { s == "debug" || s == "info" || s == "warn" || s == "error" }

fn valid_log_format(s: const u8[:]) -> bool { s == "text" || s == "json" }

// config_from(args()), then --probe: GET http://127.0.0.1:PORT/__gweb/ready; exit 0 on 200, else 1.
fn config_from_args() -> Config {
    let argv = args();
    var a: (const u8[:])[>..] = [];
    var i = 0;
    while i < argv.len { a.push(argv[i]); i += 1; }
    let cfg = config_from(a);
    if cfg.probe { exit(probe(cfg.port)); }
    return cfg;
}

fn probe(port: i64) -> i64 {
    var url: u8[>..] = [];
    format(url, "http://127.0.0.1:", port, "/__gweb/ready");
    var body: u8[>..] = [];
    let status, ok = http::get(url, body);
    return if ok && http::code(status) == 200 { 0 } else { 1 };
}

// Reads --port N, --host H, --workers N, --log, --idle-ms N, --max-body N, --drain-ms N, --drain-delay-ms N,
// --log-format text|json, --log-level debug|info|warn|error, --metrics, --job-runners N, --job-queue N,
// --job-attempts N, --no-schedule, --probe, and the environment: PORT, WEB_WORKERS, GWEB_DRAIN_MS,
// GWEB_DRAIN_DELAY_MS, GWEB_LOG_FORMAT, GWEB_LOG_LEVEL, GWEB_METRICS=1, GWEB_JOB_RUNNERS, GWEB_SCHEDULE=0 (flags win).
// a[0] is the program name. Exits with 2 on a bad flag.
fn config_from(a: (const u8[:])[:]) -> Config {
    var cfg = default_config();
    var e: u8[>..] = [];
    if env("PORT", e) { let p, ok = parse_int(trim(e)); if ok { cfg.port = p; } }
    e.clear();
    if env("WEB_WORKERS", e) { let w, ok = parse_int(trim(e)); if ok && w > 0 { cfg.workers = w; } }
    let drain, has_drain = env_int("GWEB_DRAIN_MS");
    if has_drain && drain >= 0 { cfg.drain_ms = drain; }
    let delay, has_delay = env_int("GWEB_DRAIN_DELAY_MS");
    if has_delay && delay >= 0 { cfg.drain_delay_ms = delay; }
    let runners, has_runners = env_int("GWEB_JOB_RUNNERS");
    if has_runners && runners >= 0 { cfg.job_runners = runners; }
    e.clear();
    if env("GWEB_LOG_FORMAT", e) && valid_log_format(trim(e)) { cfg.log_format.clear(); cfg.log_format.append(trim(e)); }
    e.clear();
    if env("GWEB_LOG_LEVEL", e) && valid_log_level(trim(e)) { cfg.log_level.clear(); cfg.log_level.append(trim(e)); }
    e.clear();
    if env("GWEB_METRICS", e) && trim(e) == "1" { cfg.metrics = true; }
    e.clear();
    if env("GWEB_SCHEDULE", e) && trim(e) == "0" { cfg.schedule = false; }
    var i = 1;
    while i < a.len {
        let flag = a[i];
        let has_value = i + 1 < a.len;
        if flag == "--log" { cfg.log = true; i += 1; continue; }
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
            if flag == "--dev-id" && ok { cfg.dev_id = n; i += 2; continue; }
            if flag == "--drain-ms" && ok && n >= 0 { cfg.drain_ms = n; i += 2; continue; }
            if flag == "--drain-delay-ms" && ok && n >= 0 { cfg.drain_delay_ms = n; i += 2; continue; }
            if flag == "--job-runners" && ok && n >= 0 { cfg.job_runners = n; i += 2; continue; }
            if flag == "--job-queue" && ok && n > 0 { cfg.job_queue = n; i += 2; continue; }
            if flag == "--job-attempts" && ok && n > 0 { cfg.job_attempts = n; i += 2; continue; }
            if flag == "--log-format" && valid_log_format(v) { cfg.log_format.clear(); cfg.log_format.append(v); i += 2; continue; }
            if flag == "--log-level" && valid_log_level(v) { cfg.log_level.clear(); cfg.log_level.append(v); i += 2; continue; }
            if flag == "--host" { cfg.host.clear(); cfg.host.append(v[..min(v.len, 64)]); i += 2; continue; }
        }
        print("unknown or incomplete flag: ", flag);
        print("flags: --port N --host H --workers N --log --idle-ms N --max-body N --drain-ms N --drain-delay-ms N --log-format text|json --log-level debug|info|warn|error --metrics --job-runners N --job-queue N --job-attempts N --no-schedule --probe (--dev-id N: gweb dev only)");
        exit(2);
    }
    return cfg;
}

// ---------------------------------------------------------------- the worker loop

// D, the generated dispatcher, returns the index of a static file to send, or -1; S gives its bytes, sent without a copy.
// routes is the route patterns joined by newlines, in the order of the indexes D puts in ctx.route; it names the
// route in the access log and in spans. Returns when the process is stopping and this worker has drained.
fn run_worker<D, S>(slot: i64, server: net::Socket, owner_fd: i32, cfg: Config, routes: const u8[:] = "") {
    // One worker takes every waiting connection per pass; several take one each, so a burst spreads.
    let lp = net::connection_loop(server, cfg.idle_ms, cfg.max_body, if cfg.workers == 1 { 0 } else { 1 });
    let tracing = c_otel_on() != 0;
    let json_log = cfg.log_format == "json";
    let timed = cfg.log || cfg.metrics || tracing;
    let want_id = cfg.log || tracing;
    var raw: u8[>..] = [];
    loop {
        raw.clear();
        let conn, ev = lp.next(raw);
        if cfg.metrics { c_metrics_conn(slot as i32, lp.open_connections()); }
        var res = http::new_response();
        match ev {
            Request => {
                let t0 = if timed { c_now_us() } else { 0 };
                let req, parsed = http::parse_request(raw);
                var ctx = new_ctx(slot, owner_fd);
                var keep = false;
                var static_index = -1;
                var internal = false;   // answered here: not logged, not counted
                match parsed {
                    Ready => {
                        keep = http::wants_keep_alive(req);
                        let p = req.path;
                        let get_like = req.method == http::Method.Get || req.method == http::Method.Head;
                        if cfg.dev_id != 0 && p == "/__gweb/id" {
                            dev_status(res, cfg.dev_id);
                            internal = true;
                        } else if get_like && p == "/__gweb/health" {
                            http::text(res, http::Status.Ok, "ok\n");
                            http::set_header(res, "Cache-Control", "no-store");
                            internal = true;
                        } else if get_like && p == "/__gweb/ready" {
                            if net::stopping() { http::text(res, http::Status.ServiceUnavailable, "stopping\n"); }
                            else { http::text(res, http::Status.Ok, "ready\n"); }
                            http::set_header(res, "Cache-Control", "no-store");
                            internal = true;
                        } else if get_like && cfg.metrics && p == "/__gweb/metrics" {
                            http::text(res, http::Status.Ok, "");
                            res.content_type.clear();
                            res.content_type.append("text/plain; version=0.0.4; charset=utf-8");
                            c_metrics_render(res.body, trim(WEB_VERSION));
                            http::set_header(res, "Cache-Control", "no-store");
                            internal = true;
                        } else if get_like && p.len > 1 && p[p.len - 1] == '/' {
                            if want_id { begin_request(req, ctx, tracing); }
                            var to: u8[>..] = [];
                            to.append(p[..p.len - 1]);
                            if req.query.len > 0 { to.push('?'); to.append(req.query); }
                            res.status = http::Status.PermanentRedirect;
                            http::set_header(res, "Location", to);
                        } else {
                            if want_id { begin_request(req, ctx, tracing); }
                            ctx.start_us = t0;
                            static_index = D(req, ctx, res);
                            if !apply_cookies(ctx, res) { static_index = -1; }
                            if !ctx.fragment { dev_inject(res, cfg.dev_id); }
                        }
                    },
                    Reject r => http::json_error(res, r.status, http::reason(r.status)),
                    Closed => {},
                }
                keep = keep && !net::draining();
                if ctx.request_id.len > 0 { http::add_header(res, "X-Request-Id", ctx.request_id); }
                let head_only = req.method == http::Method.Head;
                let sent = if static_index >= 0 {
                    http::send_response_with(conn, res, S(static_index), head_only, keep)
                } else {
                    http::send_response(conn, res, head_only, keep)
                };
                if !internal && (cfg.log || cfg.metrics || ctx.sampled) {
                    let dur = c_now_us() - t0;
                    let route_index = if static_index >= 0 { -2 } else { ctx.route };
                    if cfg.metrics {
                        c_metrics_request(slot as i32, route_index as i32, method_index(req.method) as i32,
                                          http::code(res.status) as i32, dur);
                    }
                    if cfg.log || ctx.sampled {
                        let label = if static_index >= 0 { "static" } else { route_name(routes, ctx.route) };
                        if cfg.log {
                            let blen = if static_index >= 0 { S(static_index).len } else { res.body.len };
                            var line: u8[>..] = [];
                            access_line(line, json_log, slot, req.method_text, req.target, label, res.status, dur, blen,
                                        ctx.request_id, ctx.trace_id, ctx.span_id);
                            log_write(Level.Info, line);
                        }
                        if ctx.sampled { push_server_span(ctx, req, label, res.status, dur); }
                    }
                }
                if !sent || !keep { lp.close_connection(conn); }
            },
            Stopped => { lp.free(); return; },
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

fn level_name(l: Level) -> const u8[:] {
    match l { Debug => "debug", Info => "info", Warn => "warn", Error => "error" }
}

fn level_num(l: Level) -> i64 {
    match l { Debug => 0, Info => 1, Warn => 2, Error => 3 }
}

// "info" for anything that is not a level name.
fn level_from_name(s: const u8[:]) -> Level {
    if s == "debug" { return Level.Debug; }
    if s == "warn" { return Level.Warn; }
    if s == "error" { return Level.Error; }
    return Level.Info;
}

// Sets the level and format every log_write and log_message uses (process-wide, in C).
fn log_configure(level: Level, json: bool) {
    c_log_config(level_num(level) as i32, if json { 1 } else { 0 });
}

// Writes one finished line (no newline needed) when level is at or above the configured one.
fn log_write(level: Level, line: const u8[:]) {
    let floor = c_log_level() as i64;
    if level_num(level) < floor { return; }
    c_log_line(line);
}

// A framework message: the text as it is in text format, {"ts","level","msg"} in json format.
fn log_message(level: Level, msg: const u8[:]) {
    var line: u8[>..] = [];
    if c_log_json() != 0 {
        line.append("{\"ts\":\"");
        c_rfc3339(line);
        format(line, "\",\"level\":\"", level_name(level), "\",\"msg\":\"");
        json_escape(line, msg);
        line.append("\"}");
    } else {
        line.append(msg);
    }
    log_write(level, line);
}

// The bytes of one JSON string body: " and \ with a backslash, bytes below 0x20 as \u00XX, the rest as they are.
fn json_escape_byte(out: u8[>..]&, c: u8) {
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
    for c in s { json_escape_byte(out, c); }
}

// Like json_escape, but stops before the byte that would take out past max bytes; false when it stopped.
fn json_escape_max(out: u8[>..]&, s: const u8[:], max: i64) -> bool {
    for c in s {
        let width = if c == 34 || c == '\\' { 2 } else if c < 32 { 6 } else { 1 };
        if out.len + width > max { return false; }
        json_escape_byte(out, c);
    }
    return true;
}

// 1 to 64 bytes of [A-Za-z0-9._-]: what run_worker accepts as the request's X-Request-Id.
fn request_id_valid(s: const u8[:]) -> bool {
    if s.len < 1 || s.len > 64 { return false; }
    for c in s {
        let ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        if !ok { return false; }
    }
    return true;
}

// The order of http::Method, which the metrics table indexes by.
fn method_index(m: http::Method) -> i64 {
    match m { Get => 0, Head => 1, Post => 2, Put => 3, Patch => 4, Delete => 5, Options => 6, Other => 7 }
}

// Line i of routes (patterns joined by newlines); "" when there is none.
fn route_name(routes: const u8[:], i: i64) -> const u8[:] {
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
fn begin_request(req: const http::Request&, ctx: Ctx&, tracing: bool) {
    let sent, has = http::header(req, "x-request-id");
    if has && request_id_valid(trim(sent)) {
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

fn push_server_span(ctx: const Ctx&, req: const http::Request&, route: const u8[:], status: http::Status, dur_us: i64) {
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
fn access_line(out: u8[>..]&, json: bool, slot: i64, method: const u8[:], target: const u8[:], route: const u8[:],
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
