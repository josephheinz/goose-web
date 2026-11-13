// Security headers, CSP and CORS (DESIGN-ADDENDUM-13, D7 and D8), without sockets.
//   goose build test/security_test.goose && test/security_test
import gweb from "..";
import gweb.auth.cors;
import gweb.site.template;
import net from "../../goose-net";
import net.http;
import std;

var failures = 0;
var checks = 0;

fn check(ok: bool, what: const u8[:]) {
    checks += 1;
    if !ok { failures += 1; print("FAIL ", what); }
}
fn check_eq(got: const u8[:], want: const u8[:], what: const u8[:]) {
    checks += 1;
    if got != want { failures += 1; print("FAIL ", what, ": got '", got, "' want '", want, "'"); }
}

let DEFAULTS = "X-Content-Type-Options: nosniff\r\nReferrer-Policy: strict-origin-when-cross-origin\r\nX-Frame-Options: SAMEORIGIN\r\n";

fn html_res() -> http::Response {
    var res = http::new_response();
    res.content_type.clear();
    res.content_type.append("text/html; charset=utf-8");
    return res;
}

fn security_tests() {
    var cfg = gweb::default_config();
    check(cfg.security_headers && cfg.hsts == 0 && cfg.csp == 0, "config defaults");

    var ctx = gweb::new_ctx(0, -1);
    var res = html_res();
    check(gweb::apply_security(ctx, res, cfg), "defaults apply");
    check_eq(res.headers, DEFAULTS, "exact default block");

    var off = gweb::default_config();
    off.security_headers = false;
    var res2 = html_res();
    var octx = gweb::new_ctx(0, -1);
    check(gweb::apply_security(octx, res2, off), "opt-out by config");
    check_eq(res2.headers, "", "no headers when security_headers is false");

    var ctx3 = gweb::new_ctx(0, -1);
    ctx3.default_headers = false;
    var res3 = html_res();
    check(gweb::apply_security(ctx3, res3, cfg), "opt-out by ctx");
    check_eq(res3.headers, "", "no headers when ctx.default_headers is false");

    var hs = gweb::default_config();
    hs.hsts = 31536000;
    var res4 = html_res();
    var ctx4 = gweb::new_ctx(0, -1);
    check(gweb::apply_security(ctx4, res4, hs), "hsts applies");
    var want4: u8[>..] = [];
    format(want4, DEFAULTS, "Strict-Transport-Security: max-age=31536000; includeSubDomains\r\n");
    check_eq(res4.headers, want4, "hsts line after the defaults");

    var res5 = html_res();
    format(res5.headers, "X-Fill: ");
    while res5.headers.len < res5.headers.cap - 10 { res5.headers.push('a'); }
    var ctx5 = gweb::new_ctx(0, -1);
    check(!gweb::apply_security(ctx5, res5, cfg), "overflow refused");
    check(res5.headers.len == 0 && http::code(res5.status) == 500, "overflow becomes the 500");
    check(find(res5.body, "response headers too large") >= 0, "overflow body");
}

fn csp_tests() {
    var cfg = gweb::default_config();
    var ctx = gweb::new_ctx(0, -1);
    check(ctx.nonce.len == 0, "no nonce by default");
    var res = html_res();
    gweb::apply_security(ctx, res, cfg);
    check(find(res.headers, "Content-Security-Policy") < 0, "no CSP without a nonce");

    check(gweb::make_nonce(ctx), "make_nonce");
    check(ctx.nonce.len == 22, "nonce is 22 bytes");
    var ok = true;
    for c in ctx.nonce { if find("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_", [c]) < 0 { ok = false; } }
    check(ok, "nonce is b64url");
    var first: u8[>..] = [];
    first.append(ctx.nonce);
    check(gweb::make_nonce(ctx) && ctx.nonce == first, "make_nonce keeps an existing nonce");
    var ctx2 = gweb::new_ctx(0, -1);
    gweb::make_nonce(ctx2);
    check(ctx2.nonce != ctx.nonce, "nonce differs between contexts");
    check_eq(gweb::nonce(ctx), first, "template nonce");

    cfg.csp = 1;
    var res2 = html_res();
    check(gweb::apply_security(ctx, res2, cfg), "csp applies");
    var want: u8[>..] = [];
    format(want, DEFAULTS, "Content-Security-Policy: script-src 'self' 'nonce-", first,
           "'; object-src 'none'; base-uri 'self'; frame-ancestors 'self'\r\n");
    check_eq(res2.headers, want, "exact CSP line after the defaults");

    var res3 = http::new_response();
    gweb::apply_security(ctx, res3, cfg);
    check(find(res3.headers, "Content-Security-Policy") < 0, "no CSP for text/plain");

    cfg.csp = 2;
    var res4 = html_res();
    gweb::apply_security(ctx, res4, cfg);
    check(find(res4.headers, "Content-Security-Policy-Report-Only: script-src 'self' 'nonce-") >= 0, "report-only name");

    // csp_begin with WEB_CSP off enforces
    var off = gweb::default_config();
    var ctx5 = gweb::new_ctx(0, -1);
    check(gweb::csp_begin(ctx5), "csp_begin");
    var res5 = html_res();
    gweb::apply_security(ctx5, res5, off);
    check(find(res5.headers, "\r\nContent-Security-Policy: script-src") >= 0, "csp_begin enforces when config is off");

    // dev_inject
    var res6 = html_res();
    gweb::dev_inject(res6, 7, first);
    var tag: u8[>..] = [];
    format(tag, "<script nonce=\"", first, "\">");
    check(find(res6.body, tag) >= 0, "dev_inject writes the nonce");
    var res7 = html_res();
    gweb::dev_inject(res7, 7, "");
    check(starts_with(res7.body, "<script>"), "dev_inject without a nonce");
}

// A request with an Origin and optional extra header lines; raw must outlive req.
fn build(raw: u8[>..]&, method: const u8[:], origin: const u8[:], extra: const u8[:]) {
    format(raw, method, " /api HTTP/1.1\r\nHost: a\r\n");
    if origin.len > 0 { format(raw, "Origin: ", origin, "\r\n"); }
    format(raw, extra, "\r\n");
}

fn run_cors(method: const u8[:], origin: const u8[:], extra: const u8[:], opts: gweb::CorsOptions, res: http::Response&) -> bool {
    var raw: u8[>..] = [];
    build(raw, method, origin, extra);
    let req, parsed = http::parse_request(raw);
    var ctx = gweb::new_ctx(0, -1);
    return gweb::cors(req, ctx, res, opts);
}

fn cors_tests() {
    var opts = gweb::CorsOptions { origins: "https://a.example, https://b.example", .. };
    let PRE = "Access-Control-Request-Method: POST\r\n";

    var r1 = http::new_response();
    check(run_cors("GET", "", "", opts, r1), "no Origin continues");
    check_eq(r1.headers, "", "no Origin adds nothing");

    var r2 = http::new_response();
    check(run_cors("GET", "https://b.example", "", opts, r2), "allowed origin continues");
    check_eq(r2.headers, "Access-Control-Allow-Origin: https://b.example\r\nVary: Origin\r\n", "allowed origin headers");

    var r3 = http::new_response();
    check(run_cors("GET", "https://evil.example", "", opts, r3), "disallowed GET continues");
    check_eq(r3.headers, "", "disallowed GET gets no CORS headers");
    var r3b = http::new_response();
    check(run_cors("POST", "https://evil.example", "", opts, r3b), "disallowed unsafe without credentials continues");
    check_eq(r3b.headers, "", "disallowed unsafe adds nothing");

    var r4 = http::new_response();
    check(!run_cors("OPTIONS", "https://a.example", PRE, opts, r4), "preflight is final");
    check(http::code(r4.status) == 204, "preflight 204");
    check_eq(r4.headers,
        "Access-Control-Allow-Origin: https://a.example\r\nVary: Origin\r\nAccess-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE\r\nAccess-Control-Allow-Headers: Content-Type, X-CSRF-Token\r\nAccess-Control-Max-Age: 600\r\n",
        "preflight headers exact");

    var r5 = http::new_response();
    check(!run_cors("OPTIONS", "https://evil.example", PRE, opts, r5), "preflight refused is final");
    check(http::code(r5.status) == 403, "preflight refused 403");
    check_eq(r5.body, "CORS origin not allowed\n", "preflight refused body");
    check_eq(r5.headers, "", "preflight refused headers");

    var r6 = http::new_response();
    check(run_cors("OPTIONS", "https://evil.example", "", opts, r6), "OPTIONS without request-method is no preflight");

    var star = gweb::CorsOptions { origins: "*", .. };
    var r7 = http::new_response();
    check(run_cors("GET", "https://any.example", "", star, r7), "star continues");
    check_eq(r7.headers, "Access-Control-Allow-Origin: *\r\nVary: Origin\r\n", "star without credentials");

    var starc = gweb::CorsOptions { origins: "*", credentials: true, .. };
    var r8 = http::new_response();
    check(run_cors("GET", "https://any.example", "", starc, r8), "star with credentials continues");
    check_eq(r8.headers, "", "star with credentials matches nothing");
    var r8b = http::new_response();
    check(!run_cors("POST", "https://any.example", "", starc, r8b) && http::code(r8b.status) == 403, "star with credentials refuses unsafe");

    var cred = gweb::CorsOptions { origins: "https://a.example", credentials: true, .. };
    var r9 = http::new_response();
    check(run_cors("GET", "https://a.example", "", cred, r9), "credentials allowed continues");
    check_eq(r9.headers, "Access-Control-Allow-Origin: https://a.example\r\nVary: Origin\r\nAccess-Control-Allow-Credentials: true\r\n", "credentials header");

    var r10 = http::new_response();
    check(!run_cors("POST", "https://evil.example", "", cred, r10), "credentialed unsafe from a disallowed origin is final");
    check(http::code(r10.status) == 403, "credentialed unsafe 403");
    check_eq(r10.body, "CORS origin not allowed\n", "credentialed unsafe body");
    var r10b = http::new_response();
    check(run_cors("GET", "https://evil.example", "", cred, r10b), "credentialed safe from a disallowed origin continues");

    var r11 = http::new_response();
    check(run_cors("POST", "https://a.example", "", cred, r11), "allowed unsafe continues");

    var r12 = http::new_response();
    for i in 4070 { r12.headers.push('a'); }
    check(!run_cors("GET", "https://a.example", "", opts, r12), "header overflow is final");
    check(http::code(r12.status) == 500 && r12.headers.len == 0, "header overflow is the 500");
}

fn main() {
    security_tests();
    csp_tests();
    cors_tests();
    print(checks - failures, " of ", checks, " checks pass");
    if failures > 0 { exit(1); }
}
