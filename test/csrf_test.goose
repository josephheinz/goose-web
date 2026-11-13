// CSRF token helpers (DESIGN-ADDENDUM-7), without sockets.
//   goose build test/csrf_test.goose && test/csrf_test
import gweb from "..";
import gweb.auth.csrf;
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

let T = "0123456789abcdef0123456789abcdef";
let W = "ffffffffffffffffffffffffffffffff";
let COOKIE = "Cookie: gw_csrf=0123456789abcdef0123456789abcdef\r\n";
let HEADER = "X-CSRF-Token: 0123456789abcdef0123456789abcdef\r\n";
let BAD_HEADER = "X-CSRF-Token: ffffffffffffffffffffffffffffffff\r\n";
let BODY = "_csrf=0123456789abcdef0123456789abcdef";
let FORM = "Content-Type: application/x-www-form-urlencoded\r\n";
let DENIED = "CSRF token missing or wrong; reload the page and try again\n";
let CROSS = "cross-site request refused\n";

fn count(s: const u8[:], sub: const u8[:]) -> i64 {
    var n = 0;
    var rest = s;
    loop {
        let i = find(rest, sub);
        if i < 0 { return n; }
        n += 1;
        rest = rest[i + sub.len..];
    }
}

// Runs csrf_ok on a request built from method, header lines and body.
fn run(method: const u8[:], headers: const u8[:][:], body: const u8[:], res: http::Response&) -> bool {
    var raw: u8[>..] = [];
    format(raw, method, " / HTTP/1.1\r\nHost: a\r\n");
    for h in headers { format(raw, h); }
    format(raw, "Content-Length: ", body.len, "\r\n\r\n", body);
    let req, parsed = http::parse_request(raw);
    if parsed != http::Read.Ready { failures += 1; print("FAIL request did not parse: ", raw); }
    return gweb::_csrf_ok(req, res);
}

fn verdict(method: const u8[:], headers: const u8[:][:], body: const u8[:]) -> bool {
    var res = http::new_response();
    return run(method, headers, body, res);
}

fn main() {
    // csrf_valid
    check(gweb::_csrf_valid(T), "valid 32");
    check(!gweb::_csrf_valid(T[..31]), "31 digits");
    check(!gweb::_csrf_valid("0123456789abcdef0123456789abcdef0"), "33 digits");
    check(!gweb::_csrf_valid("0123456789ABCDEF0123456789abcdef"), "uppercase");
    check(!gweb::_csrf_valid("0123456789abcdeg0123456789abcdef"), "g is not hex");
    check(!gweb::_csrf_valid(""), "empty");

    // csrf_cookie_name
    let plain, p1 = http::parse_request("GET / HTTP/1.1\r\nHost: a\r\n\r\n");
    check_eq(gweb::_csrf_cookie_name(plain), "gw_csrf", "name without proxy header");
    let https, p2 = http::parse_request("GET / HTTP/1.1\r\nHost: a\r\nX-Forwarded-Proto: https\r\n\r\n");
    check_eq(gweb::_csrf_cookie_name(https), "__Host-gw_csrf", "name under https");
    let spaced, p3 = http::parse_request("GET / HTTP/1.1\r\nHost: a\r\nX-Forwarded-Proto:  https \r\n\r\n");
    check_eq(gweb::_csrf_cookie_name(spaced), "__Host-gw_csrf", "https with spaces");
    let http1, p4 = http::parse_request("GET / HTTP/1.1\r\nHost: a\r\nX-Forwarded-Proto: http\r\n\r\n");
    check_eq(gweb::_csrf_cookie_name(http1), "gw_csrf", "name under http");

    // csrf_begin without a cookie
    var ctx = gweb::_new_ctx(0, -1);
    var res = http::new_response();
    check(gweb::csrf_begin(plain, ctx, res), "begin without cookie");
    check(gweb::_csrf_valid(ctx.csrf), "minted token is 32 hex");
    let first = ctx.csrf;
    var want_line: u8[..160] = "";
    format(want_line, "Set-Cookie: gw_csrf=", ctx.csrf, "; Path=/; HttpOnly; SameSite=Lax\r\n");
    check_eq(ctx.set_cookies, want_line, "minted cookie line");
    check_eq(res.headers, "Cache-Control: no-store\r\n", "one Cache-Control: no-store");

    // again on the same ctx
    check(gweb::csrf_begin(plain, ctx, res) && ctx.csrf == first, "second begin keeps the token");
    check(count(ctx.set_cookies, "Set-Cookie") == 1 && count(res.headers, "Cache-Control") == 1, "still one Set-Cookie and one Cache-Control");

    // fresh tokens
    var ctx_b = gweb::_new_ctx(0, -1);
    var res_b = http::new_response();
    gweb::csrf_begin(plain, ctx_b, res_b);
    check(ctx_b.csrf != first, "two fresh tokens differ");
    check(ctx_b.csrf != "00000000000000000000000000000000", "a token is not 32 zeros");

    // a valid cookie
    let have, p5 = http::parse_request("GET / HTTP/1.1\r\nHost: a\r\nCookie: theme=dark; gw_csrf=0123456789abcdef0123456789abcdef\r\n\r\n");
    var ctx_c = gweb::_new_ctx(0, -1);
    var res_c = http::new_response();
    gweb::csrf_begin(have, ctx_c, res_c);
    check_eq(ctx_c.csrf, T, "cookie reused");
    check(ctx_c.set_cookies.len == 0, "no Set-Cookie when reused");
    check_eq(res_c.headers, "Cache-Control: no-store\r\n", "reuse still sets no-store");

    // an invalid cookie
    let upper, p6 = http::parse_request("GET / HTTP/1.1\r\nHost: a\r\nCookie: gw_csrf=0123456789ABCDEF0123456789ABCDEF\r\n\r\n");
    var ctx_d = gweb::_new_ctx(0, -1);
    var res_d = http::new_response();
    gweb::csrf_begin(upper, ctx_d, res_d);
    check(gweb::_csrf_valid(ctx_d.csrf) && ctx_d.csrf != "0123456789ABCDEF0123456789ABCDEF" && starts_with(ctx_d.set_cookies, "Set-Cookie: gw_csrf="), "uppercase cookie replaced");

    // https
    let hs, p7 = http::parse_request("GET / HTTP/1.1\r\nHost: a\r\nX-Forwarded-Proto: https\r\n\r\n");
    var ctx_e = gweb::_new_ctx(0, -1);
    var res_e = http::new_response();
    gweb::csrf_begin(hs, ctx_e, res_e);
    var want_host: u8[..160] = "";
    format(want_host, "Set-Cookie: __Host-gw_csrf=", ctx_e.csrf, "; Path=/; Secure; HttpOnly; SameSite=Lax\r\n");
    check_eq(ctx_e.set_cookies, want_host, "__Host- cookie line");
    let hs2, p8 = http::parse_request("GET / HTTP/1.1\r\nHost: a\r\nX-Forwarded-Proto: https\r\nCookie: gw_csrf=0123456789abcdef0123456789abcdef\r\n\r\n");
    var ctx_f = gweb::_new_ctx(0, -1);
    var res_f = http::new_response();
    gweb::csrf_begin(hs2, ctx_f, res_f);
    check(ctx_f.csrf != T && starts_with(ctx_f.set_cookies, "Set-Cookie: __Host-gw_csrf="), "plain cookie ignored under https");

    // a cookie buffer too full for the 86-byte token line
    var ctx_g = gweb::_new_ctx(0, -1);
    var res_g = http::new_response();
    var fill: u8[>..] = [];
    for i in 1000 { fill.push('p'); }
    gweb::set_cookie(ctx_g, "a", fill);
    gweb::set_cookie(ctx_g, "b", fill[..900]);
    check(!gweb::csrf_begin(plain, ctx_g, res_g), "begin with no room");
    check(res_g.status == http::Status.InternalServerError && ctx_g.csrf.len == 0, "500 and no token");

    // fragment_reply after csrf_begin
    let frag, p9 = http::parse_request("GET / HTTP/1.1\r\nHost: a\r\nGW-Fragment: list\r\n\r\n");
    var ctx_h = gweb::_new_ctx(0, -1);
    var res_h = http::new_response();
    gweb::csrf_begin(plain, ctx_h, res_h);
    gweb::_fragment_reply(frag, ctx_h, res_h);
    check(count(res_h.headers, "Cache-Control") == 1, "fragment_reply adds no second Cache-Control");

    // csrf_field and csrf_token
    var out: u8[>..] = [];
    gweb::csrf_field(out, ctx_c);
    check_eq(out, "<input type=\"hidden\" name=\"_csrf\" value=\"0123456789abcdef0123456789abcdef\">", "field bytes");
    check_eq(gweb::csrf_token(ctx_c), ctx_c.csrf, "csrf_token is ctx.csrf");
    var out2: u8[>..] = [];
    let blank = gweb::_new_ctx(0, -1);
    gweb::csrf_field(out2, blank);
    check_eq(out2, "<input type=\"hidden\" name=\"_csrf\" value=\"\">", "field before begin");

    // csrf_ok: safe methods
    var res_s = http::new_response();
    check(run("GET", [], "", res_s) && res_s.status == http::Status.Ok && res_s.body.len == 0 && res_s.headers.len == 0, "GET passes and leaves res alone");
    check(verdict("HEAD", [], ""), "HEAD passes");
    check(verdict("OPTIONS", [], ""), "OPTIONS passes");

    // csrf_ok: POST
    check(verdict("POST", [COOKIE, FORM], BODY), "cookie and field");
    check(verdict("POST", [COOKIE, HEADER], ""), "cookie and header");
    check(!verdict("POST", [COOKIE, BAD_HEADER, FORM], BODY), "a wrong header beats a right field");
    var res_n = http::new_response();
    check(!run("POST", [HEADER], "", res_n) && res_n.status == http::Status.Forbidden, "no cookie gives 403");
    check(!verdict("POST", [COOKIE], ""), "cookie and no token");
    check(!verdict("POST", [COOKIE, FORM], "_csrf=0123456789abcdef0123456789abcdee"), "one digit off");
    check(!verdict("POST", ["Cookie: gw_csrf=abc\r\n", FORM], "_csrf=abc"), "equal but invalid");
    var res_t = http::new_response();
    run("POST", [], "", res_t);
    check_eq(res_t.body, DENIED, "token 403 body");
    var res_x = http::new_response();
    check(!run("POST", ["Sec-Fetch-Site: cross-site\r\n", COOKIE, HEADER], "", res_x) && res_x.body == CROSS, "cross-site refused with the exact body");
    check(!verdict("POST", ["Sec-Fetch-Site: same-site\r\n", COOKIE, HEADER], ""), "same-site refused");
    check(verdict("POST", ["Sec-Fetch-Site: same-origin\r\n", COOKIE, HEADER], ""), "same-origin passes");
    check(verdict("POST", ["Sec-Fetch-Site: none\r\n", COOKIE, HEADER], ""), "none passes");

    // other unsafe methods
    check(!verdict("PUT", [], ""), "PUT checked");
    check(!verdict("PATCH", [], ""), "PATCH checked");
    check(!verdict("DELETE", [], ""), "DELETE checked");

    // body shapes and HTTPS
    check(verdict("POST", [COOKIE, HEADER, "Content-Type: application/json\r\n"], "{}"), "json body with the header");
    check(!verdict("POST", ["X-Forwarded-Proto: https\r\n", COOKIE, HEADER], ""), "plain cookie refused under https");
    check(verdict("POST", ["X-Forwarded-Proto: https\r\n", "Cookie: __Host-gw_csrf=0123456789abcdef0123456789abcdef\r\n", HEADER], ""), "__Host- cookie passes under https");
    check(verdict("POST", [COOKIE, FORM], "title=x&_csrf=0123456789abcdef0123456789abcdef&add=1"), "the field among others");

    print(checks - failures, " of ", checks, " checks pass");
    if failures > 0 { exit(1); }
}
