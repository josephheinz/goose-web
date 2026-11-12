// Cookie helpers (DESIGN-ADDENDUM-5), without sockets.
//   goose build test/cookie_test.goose && test/cookie_test
import web from "..";
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

struct Props { theme: const u8[:], path: const u8[:], visits: i64 }

// The loader shape: Props holds slices into req while ctx gets a cookie.
fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    let n, has = web::cookie_int(req, "visits");
    var text: u8[..24] = "";
    format(text, n + 1);
    web::set_cookie(ctx, "visits", text, web::CookieOptions { max_age: 60, .. });
    return Props { theme: web::cookie_or(req, "theme", "light"), path: req.path, visits: n + 1 };
}

// The handler shape: res shrinks while cookie views into req stay in use.
fn handler(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    let theme = web::cookie_or(req, "theme", "light");
    res.body.append("discarded");
    res.body.clear();
    web::set_cookie(ctx, "seen", "1");
    http::json_error(res, http::Status.BadRequest, theme);
    res.body.clear();
    res.body.append(theme);
}

fn main() {
    let raw = "GET /p?x=1 HTTP/1.1\r\nHost: a\r\nCookie: a=1;  theme = dark ;bad; =x; q=\"quoted\"; a=2; enc=a%20b%3B%zz+; visits=41; empty=\r\nCookie: second=1\r\n\r\n";
    let req, parsed = http::parse_request(raw);
    let v, has = http::cookie(req, "a");
    check_eq(v, "1", "first duplicate wins"); check(has, "a present");
    let t, has_t = http::cookie(req, "theme");
    check_eq(t, "dark", "whitespace trimmed");
    let q, has_q = http::cookie(req, "q");
    check_eq(q, "quoted", "quotes removed");
    let b, has_b = http::cookie(req, "bad");
    check(!has_b, "pair without = skipped");
    let e0, has_e0 = http::cookie(req, "");
    check(!has_e0, "empty name never matches");
    let s2, has_s2 = http::cookie(req, "second");
    check(!has_s2, "second Cookie header ignored");
    let up, has_up = http::cookie(req, "Theme");
    check(!has_up, "names are case-sensitive");
    let em, has_em = http::cookie(req, "empty");
    check(has_em && em.len == 0, "empty value present");
    var out: u8[>..] = [];
    check(web::cookie(req, "enc", out), "enc present");
    check_eq(out, "a b;%zz+", "percent-decoded, + kept, bad escape kept");
    check_eq(web::cookie_or(req, "nope", "light"), "light", "cookie_or fallback");
    check_eq(web::cookie_or(req, "empty", "light"), "light", "cookie_or on empty");
    let n, n_ok = web::cookie_int(req, "visits");
    check(n_ok && n == 41, "cookie_int");
    let n2, n2_ok = web::cookie_int(req, "theme");
    check(!n2_ok, "cookie_int on text");

    let bare, bp = http::parse_request("GET / HTTP/1.1\r\nHost: a\r\n\r\n");
    let nb, has_nb = http::cookie(bare, "a");
    check(!has_nb, "no Cookie header");

    var ctx = web::new_ctx(0, -1);
    check(web::set_cookie(ctx, "theme", "dark"), "defaults");
    check_eq(ctx.set_cookies, "Set-Cookie: theme=dark; Path=/; HttpOnly; SameSite=Lax\r\n", "default line");
    ctx.set_cookies.clear();
    check(web::set_cookie(ctx, "v", "a b;=\"\r\n\x00é", web::CookieOptions { path: "/shop", domain: "example.com", max_age: 3600, secure: true, http_only: false, same_site: web::SameSite.Strict }), "all options");
    check_eq(ctx.set_cookies, "Set-Cookie: v=a%20b%3B%3D%22%0D%0A%00%C3%A9; Path=/shop; Domain=example.com; Max-Age=3600; Secure; SameSite=Strict\r\n", "full line");
    ctx.set_cookies.clear();
    check(web::set_cookie(ctx, "x", "1", web::CookieOptions { same_site: web::SameSite.None, .. }), "SameSite=None");
    check_eq(ctx.set_cookies, "Set-Cookie: x=1; Path=/; Secure; HttpOnly; SameSite=None\r\n", "None forces Secure");
    ctx.set_cookies.clear();
    check(web::clear_cookie(ctx, "theme"), "clear");
    check_eq(ctx.set_cookies, "Set-Cookie: theme=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly; SameSite=Lax\r\n", "clear line");
    ctx.set_cookies.clear();

    check(!web::set_cookie(ctx, "", "1"), "empty name");
    check(!web::set_cookie(ctx, "a b", "1"), "space in name");
    check(!web::set_cookie(ctx, "a=b", "1"), "= in name");
    check(!web::set_cookie(ctx, "a;b", "1"), "; in name");
    check(!web::set_cookie(ctx, "a\r\nX: y", "1"), "CRLF in name");
    var long_name: u8[>..] = [];
    for i in 65 { long_name.push('n'); }
    check(!web::set_cookie(ctx, long_name, "1"), "65 byte name");
    check(web::set_cookie(ctx, long_name[..64], "1"), "64 byte name");
    ctx.set_cookies.clear();
    var big: u8[>..] = [];
    for i in 1025 { big.push('v'); }
    check(!web::set_cookie(ctx, "a", big), "1025 byte value");
    check(web::set_cookie(ctx, "a", big[..1024]), "1024 byte value");
    check(!web::set_cookie(ctx, "b", big[..1024]), "second big cookie does not fit in 2048");
    check(web::set_cookie(ctx, "c", "small"), "a small one still fits");
    ctx.set_cookies.clear();
    var semis: u8[>..] = [];
    for i in 342 { semis.push(';'); }
    check(!web::set_cookie(ctx, "a", semis), "342 bytes that encode to 1026");
    check(!web::set_cookie(ctx, "a", "1", web::CookieOptions { path: "shop", .. }), "path without /");
    check(!web::set_cookie(ctx, "a", "1", web::CookieOptions { path: "/a;b", .. }), "; in path");
    check(!web::set_cookie(ctx, "a", "1", web::CookieOptions { path: "", .. }), "empty path");
    check(!web::set_cookie(ctx, "a", "1", web::CookieOptions { domain: "a.com; Secure", .. }), "bad domain");
    check(!web::set_cookie(ctx, "a", "1", web::CookieOptions { max_age: -2, .. }), "max_age -2");
    check(!web::set_cookie(ctx, "__Secure-a", "1"), "__Secure- without secure");
    check(web::set_cookie(ctx, "__Secure-a", "1", web::CookieOptions { secure: true, .. }), "__Secure- with secure");
    check(!web::set_cookie(ctx, "__Host-a", "1", web::CookieOptions { domain: "a.com", secure: true, .. }), "__Host- with domain");
    check(!web::set_cookie(ctx, "__Host-a", "1", web::CookieOptions { path: "/x", secure: true, .. }), "__Host- with path");
    check(web::set_cookie(ctx, "__Host-a", "1", web::CookieOptions { secure: true, .. }), "__Host- ok");
    ctx.set_cookies.clear();

    // apply: two lines, after an existing header, in order.
    var res = http::new_response();
    http::set_header(res, "X-A", "1");
    web::set_cookie(ctx, "one", "1");
    web::set_cookie(ctx, "two", "2");
    check(web::apply_cookies(ctx, res), "apply");
    check_eq(res.headers, "X-A: 1\r\nSet-Cookie: one=1; Path=/; HttpOnly; SameSite=Lax\r\nSet-Cookie: two=2; Path=/; HttpOnly; SameSite=Lax\r\n", "applied lines");
    check(ctx.set_cookies.len == 0, "pending cleared");
    // apply with a redirect outcome keeps both.
    var res2 = http::new_response();
    web::set_cookie(ctx, "one", "1");
    web::redirect(ctx, "/next", 303);
    web::apply_redirect(ctx, res2);
    check(web::apply_cookies(ctx, res2), "apply after redirect");
    check_eq(res2.headers, "Location: /next\r\nSet-Cookie: one=1; Path=/; HttpOnly; SameSite=Lax\r\n", "redirect and cookie");
    // apply that does not fit: 500, no headers.
    var res3 = http::new_response();
    var filler: u8[>..] = [];
    for i in 4000 { filler.push('f'); }
    check(http::add_header(res3, "X-Fill", filler), "filler fits");
    check(!http::add_header(res3, "X-More", filler), "add_header refuses overflow");
    check(!http::add_header(res3, "X", "a\r\nb"), "add_header refuses CRLF");
    web::set_cookie(ctx, "big", big[..1024]);
    check(!web::apply_cookies(ctx, res3), "apply refuses overflow");
    check(res3.status == http::Status.InternalServerError && res3.headers.len == 0, "overflow becomes a bare 500");

    // lifetime shapes
    var ctx2 = web::new_ctx(0, -1);
    var res4 = http::new_response();
    web::html(res4, http::Status.Ok);
    let props = load(req, ctx2);
    format(res4.body, props.theme, " ", props.path, " ", props.visits);
    check_eq(res4.body, "dark /p 42", "loader props");
    check_eq(ctx2.set_cookies, "Set-Cookie: visits=42; Path=/; Max-Age=60; HttpOnly; SameSite=Lax\r\n", "loader cookie");
    handler(req, ctx2, res4);
    check_eq(res4.body, "dark", "handler view survives res shrinking");
    web::apply_cookies(ctx2, res4);

    print(checks - failures, " of ", checks, " checks pass");
    if failures > 0 { exit(1); }
}
