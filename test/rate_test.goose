// client_ip, the 429 reply and rate_take_at, without sockets or a clock.
//   goose build test/rate_test.goose && test/rate_test
import gweb from "..";
import gweb.auth.rate;
import net from "../../goose-net";
import net.http;
import std;

var failures = 0;
var checks = 0;

extern fn c_rate_reset() = "gweb_rate_reset";

fn check(ok: bool, what: const u8[:]) {
    checks += 1;
    if !ok { failures += 1; print("FAIL ", what); }
}
fn check_eq(got: const u8[:], want: const u8[:], what: const u8[:]) {
    checks += 1;
    if got != want { failures += 1; print("FAIL ", what, ": got '", got, "' want '", want, "'"); }
}

fn ip_of(headers: const u8[:], trust: bool, fd: i32) -> u8[>..] {
    var raw: u8[>..] = [];
    format(raw, "GET / HTTP/1.1\r\nHost: a\r\n", headers, "\r\n");
    let req, parsed = http::parse_request(raw);
    var ctx = gweb::new_ctx(0, -1);
    ctx.auth.trust_proxy = trust;
    ctx.conn_fd = fd;
    var out: u8[>..] = [];
    gweb::client_ip(req, ctx, out);
    return out;
}

fn port_of(addr: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    gweb::strip_port(addr, out);
    return out;
}

fn main() {
    check_eq(ip_of("X-Forwarded-For: 9.9.9.9\r\n", false, -1), "", "no proxy trust and no connection: unknown");
    check_eq(ip_of("X-Forwarded-For: 9.9.9.9\r\n", true, -1), "9.9.9.9", "trusted single item");
    check_eq(ip_of("X-Forwarded-For: 1.1.1.1, 2.2.2.2 ,  3.3.3.3\r\n", true, -1), "3.3.3.3", "last item, trimmed");
    check_eq(ip_of("", true, -1), "", "trusted but no header and no connection");
    check_eq(ip_of("X-Forwarded-For: 9.9.9.9\r\n", false, 100000), "", "untrusted header is ignored, bad fd gives unknown");

    check_eq(port_of("1.2.3.4:5"), "1.2.3.4", "ipv4 port removed");
    check_eq(port_of("[::1]:5"), "::1", "bracketed ipv6 port removed");
    check_eq(port_of("::1"), "::1", "bare ipv6 kept");
    check_eq(port_of("1.2.3.4"), "1.2.3.4", "no port kept");
    check_eq(port_of(""), "", "empty stays empty");

    var res = http::new_response();
    gweb::rate_refuse(res, 1);
    check(http::code(res.status) == 429, "status 429");
    check_eq(res.headers, "Retry-After: 1\r\n", "1 ms rounds up to 1 second");
    check_eq(res.body, "too many requests; try again in 1 seconds\n", "body");
    var res2 = http::new_response();
    gweb::rate_refuse(res2, 2001);
    check_eq(res2.headers, "Retry-After: 3\r\n", "2001 ms rounds up to 3 seconds");
    check_eq(res2.body, "too many requests; try again in 3 seconds\n", "body for 3 seconds");

    c_rate_reset();
    check(gweb::rate_take_at("login\x00a", 0, 1000, 2) == 0, "first take");
    check(gweb::rate_take_at("login\x00a", 0, 1000, 2) == 0, "second take");
    check(gweb::rate_take_at("login\x00a", 0, 1000, 2) == 500, "third refused with the wait");
    check(gweb::rate_take_at("login\x00b", 0, 1000, 2) == 0, "other key independent");
    c_rate_reset();
    check(gweb::rate_take_at("login\x00a", 0, 1000, 2) == 0, "reset clears the table");

    print(checks - failures, " of ", checks, " checks pass");
    if failures > 0 { exit(1); }
}
