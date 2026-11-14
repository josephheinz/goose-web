// require_login for a fragment or boosted request (1.1): 401 with GW-Login when the request sends GW-Auth: 401, the
// 303 redirect of 1.0 when it does not. Without sockets.
//   goose build test/unauth_test.goose && test/unauth_test
import gweb from "..";
import gweb.auth.session;
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

fn ctx_keyed() -> gweb::Ctx {
    var ctx = gweb::_new_ctx(0, -1);
    ctx.auth.keys.k[0].append("0123456789abcdef0123456789abcdef");
    ctx.auth.keys.n = 1;
    return ctx;
}

fn build(raw: u8[>..]&, method: const u8[:], target: const u8[:], extra: const u8[:]) {
    raw.clear();
    format(raw, method, " ", target, " HTTP/1.1\r\nHost: a\r\n", extra, "\r\n");
}

fn main() {
    let NOW = 1000000;
    // The request says it handles a 401: GET.
    var raw1: u8[>..] = [];
    build(raw1, "GET", "/admin/posts?page=2", "GW-Fragment: list\r\nGW-Auth: 401\r\n");
    let req1, p1 = http::parse_request(raw1);
    var ctx1 = ctx_keyed();
    var res1 = http::new_response();
    check(!gweb::_require_login_at(req1, ctx1, res1, "/login", NOW), "the guard refuses");
    check(res1.status == http::Status.Unauthorized, "401");
    check(ctx1.outcome == gweb::Outcome.Continue, "no redirect");
    check_eq(res1.body, "login required", "body");
    check(find(res1.headers, "GW-Login: /login?next=%2Fadmin%2Fposts%3Fpage%3D2\r\n") >= 0, "GW-Login has the login URL with next");
    check(find(res1.headers, "Cache-Control: no-store") >= 0, "no-store");
    check(find(res1.headers, "Location:") < 0, "no Location");

    // A POST: a bare login path.
    var raw2: u8[>..] = [];
    build(raw2, "POST", "/admin/posts", "GW-Nav: 1\r\nGW-Auth: 401\r\nContent-Length: 0\r\n");
    let req2, p2 = http::parse_request(raw2);
    var ctx2 = ctx_keyed();
    var res2 = http::new_response();
    check(!gweb::_require_login_at(req2, ctx2, res2, "/login", NOW), "a POST is refused");
    check(res2.status == http::Status.Unauthorized && find(res2.headers, "GW-Login: /login\r\n") >= 0, "401 and a bare login path");

    // The same request without GW-Auth, with only GW-Fragment or GW-Nav, keeps the 1.0 redirect.
    for extra in ["GW-Fragment: list\r\n", "GW-Nav: 1\r\n", "GW-Auth: 1\r\n", ""] {
        var raw3: u8[>..] = [];
        build(raw3, "GET", "/admin", extra);
        let req3, p3 = http::parse_request(raw3);
        var ctx3 = ctx_keyed();
        var res3 = http::new_response();
        check(!gweb::_require_login_at(req3, ctx3, res3, "/login", NOW), "refused");
        check(ctx3.outcome == gweb::Outcome.Redirect && ctx3.redirect_status == 303, "still a 303 redirect");
        check_eq(ctx3.location, "/login?next=%2Fadmin", "to the login");
        check(res3.status != http::Status.Unauthorized, "not a 401");
    }

    // A logged-in request passes either way (see session_test for the cookie round trip).
    print(checks - failures, " of ", checks, " checks pass");
    if failures > 0 { exit(1); }
}
