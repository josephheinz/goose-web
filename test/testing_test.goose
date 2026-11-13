// Route test helpers (DESIGN-ADDENDUM-17), without sockets.
//   goose build test/testing_test.goose && test/testing_test
import gweb from "..";
import gweb.auth.csrf;
import gweb.testing;
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

fn dispatch(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) -> i64 {
    let p = req.path;
    if p == "/echo" {
        http::text(res, http::Status.Ok, "");
        format(res.body, req.method_text, ":", req.body);
    } else if p == "/set" {
        gweb::set_cookie(ctx, "k", "v");
        http::text(res, http::Status.Ok, "set");
    } else if p == "/clear" {
        gweb::clear_cookie(ctx, "k");
        http::text(res, http::Status.Ok, "cleared");
    } else if p == "/who" {
        http::text(res, http::Status.Ok, gweb::cookie_or(req, "k", "none"));
    } else if p == "/host" {
        let v, has = http::header(req, "host");
        http::text(res, http::Status.Ok, if has { v } else { "none" });
    } else if p == "/xtest" {
        let v, has = http::header(req, "x-test");
        http::text(res, http::Status.Ok, if has { v } else { "none" });
    } else if p == "/guard" {
        if !gweb::_csrf_ok(req, res) { return -1; }
        http::text(res, http::Status.Ok, "guarded");
    } else if p == "/static" {
        return 0;
    } else {
        gweb::_plain_not_found(res);
    }
    return -1;
}

fn static_bytes(i: i64) -> const u8[:] { "STATIC" }

fn send(t: gweb::Tester&, method: const u8[:], target: const u8[:], body: const u8[:]) -> http::Response {
    return gweb::_test_send(t, method, target, body, "text/plain", dispatch, static_bytes);
}

fn main() {
    var t = gweb::Tester { .. };
    t.name.append("testing");

    // status and body
    let r1 = send(t, "POST", "/echo", "hello");
    gweb::expect_status(t, r1, 200);
    gweb::expect_contains(t, r1.body, "POST:hello");
    check_eq(r1.body, "POST:hello", "echo body");
    gweb::expect_header(t, r1, "content-type", "text/plain; charset=utf-8");
    let r404 = send(t, "GET", "/nope", "");
    gweb::expect_status(t, r404, 404);

    // HEAD has an empty body
    let rh = send(t, "HEAD", "/who", "");
    gweb::expect_status(t, rh, 200);
    check(rh.body.len == 0, "HEAD body empty");

    // trailing slash
    let rs = send(t, "GET", "/echo/?a=1", "");
    gweb::expect_status(t, rs, 308);
    gweb::expect_header(t, rs, "Location", "/echo?a=1");

    // the jar keeps a cookie, sends it, and Max-Age=0 removes it
    var t2 = gweb::Tester { .. };
    t2.name.append("jar");
    check_eq(send(t2, "GET", "/who", "").body, "none", "no cookie yet");
    send(t2, "GET", "/set", "");
    check_eq(t2.cookies, "k=v", "jar stores name=value only");
    check_eq(send(t2, "GET", "/who", "").body, "v", "cookie sent back");
    send(t2, "GET", "/clear", "");
    check_eq(t2.cookies, "", "Max-Age=0 removes");
    check_eq(send(t2, "GET", "/who", "").body, "none", "cookie gone");
    send(t2, "GET", "/set", "");
    send(t2, "GET", "/set", "");
    check_eq(t2.cookies, "k=v", "same name replaced, not duplicated");

    // auto CSRF
    var t3 = gweb::Tester { .. };
    t3.name.append("csrf");
    let rg = send(t3, "POST", "/guard", "x=1");
    gweb::expect_status(t3, rg, 200);
    check_eq(rg.body, "guarded", "guarded body");
    check_eq(t3.cookies, "gw_csrf=00000000000000000000000000000000", "fixed token in the jar");
    var t4 = gweb::Tester { .. };
    t4.name.append("nocsrf");
    t4.auto_csrf = false;
    let r403 = send(t4, "POST", "/guard", "x=1");
    gweb::expect_status(t4, r403, 403);
    check_eq(t4.cookies, "", "no token added when auto_csrf is off");
    let rguard = send(t4, "GET", "/guard", "");
    gweb::expect_status(t4, rguard, 200);

    // t.headers is sent once
    t.headers.append("X-Test: one\r\n");
    check_eq(send(t, "GET", "/xtest", "").body, "one", "extra header sent");
    check(t.headers.len == 0, "headers cleared");
    check_eq(send(t, "GET", "/xtest", "").body, "none", "extra header not sent twice");

    // t.host is the Host header of every request
    check_eq(send(t, "GET", "/host", "").body, "test", "the default Host is test");
    t.host.clear();
    t.host.append("a.example");
    check_eq(send(t, "GET", "/host", "").body, "a.example", "t.host sets the Host header");
    check_eq(send(t, "POST", "/host", "x=1").body, "a.example", "and it holds for the next request too");
    t.host.clear();
    t.host.append("test");

    // static index
    let rst = send(t, "GET", "/static", "");
    gweb::expect_status(t, rst, 200);
    check_eq(rst.body, "STATIC", "static bytes");
    check(send(t, "HEAD", "/static", "").body.len == 0, "HEAD static body empty");

    // form_field and header_of
    var f: u8[>..] = [];
    gweb::form_field(f, "title", "a b&c");
    gweb::form_field(f, "n", "é");
    check_eq(f, "title=a%20b%26c&n=%C3%A9", "form_field encodes");
    let loc, has_loc = gweb::header_of(rs, "location");
    check(has_loc && loc == "/echo?a=1", "header_of is case-insensitive");
    let none, has_none = gweb::header_of(rs, "x-none");
    check(!has_none, "header_of absent");

    // a clean run counted checks and no failures
    check(t.failures == 0 && t.checks > 0, "good checks do not fail");

    // failing expects count
    var tf = gweb::Tester { .. };
    tf.name.append("expected-failure");
    gweb::expect(tf, true, "fine");
    gweb::expect(tf, false, "deliberate");
    gweb::expect_status(tf, r1, 500);
    gweb::expect_contains(tf, "abc", "zzz");
    gweb::expect_header(tf, r1, "x-none", "v");
    check(tf.checks == 5 && tf.failures == 4, "failing expects count");

    failures += t.failures + t2.failures + t3.failures + t4.failures;
    print(checks - failures, " of ", checks, " checks pass");
    if failures > 0 { exit(1); }
}
