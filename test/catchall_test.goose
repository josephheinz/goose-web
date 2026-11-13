// Catch-all params, set_rest and path_decode, without sockets.
//   goose build test/catchall_test.goose && test/catchall_test
import gweb from "..";
import net from "../../goose-net";
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

fn accepts(tail: const u8[:]) -> bool {
    var ctx = gweb::new_ctx(0, -1);
    return gweb::set_rest(ctx, "path", tail);
}

fn repeated(c: u8, n: i64) -> u8[>..] {
    var s: u8[>..] = [];
    for i in n { s.push(c); }
    return s;
}

fn main() {
    var ctx = gweb::new_ctx(0, -1);
    check_eq(ctx.params.rest_name, "", "new ctx has no rest name");
    check_eq(gweb::param(ctx, "path"), "", "param is empty on a new ctx");
    check_eq(gweb::param(ctx, ""), "", "empty name on a new ctx");

    check(gweb::set_param(ctx, "id", "7"), "set_param");
    check(gweb::set_rest(ctx, "path", "a/b/c"), "set_rest");
    check_eq(gweb::param(ctx, "path"), "a/b/c", "tail");
    check_eq(gweb::param(ctx, "other"), "", "another name");
    check_eq(gweb::param(ctx, "id"), "7", "set_param value still resolves");
    check(gweb::set_rest(ctx, "path", ""), "empty tail");
    check_eq(gweb::param(ctx, "path"), "", "empty tail value");
    check_eq(gweb::param(ctx, "id"), "7", "set_param survives set_rest");

    check(gweb::set_rest(ctx, "path", "caf%C3%A9"), "keeps raw text");
    check_eq(gweb::param(ctx, "path"), "caf%C3%A9", "raw tail");
    check(!gweb::set_rest(ctx, "path", "a//b"), "refused tail leaves the old value");
    check_eq(gweb::param(ctx, "path"), "caf%C3%A9", "old value stays");

    let refused: const u8[:][20] = ["a//b", "/a", "a/", "a/./b", "a/../b", "..", ".", "%2e%2e/x", "a/%2E", "%2e",
                                    "a%2Fb", "a%2fb", "a%5Cb", "a\\b", "%00", "%1f", "%7F", "%zz", "%4", "%"];
    for i in 20 { check(!accepts(refused[i]), refused[i]); }
    check(!accepts("%0A"), "%0A");
    check(!accepts("a/%2E%2e"), "%2E%2e as a segment");
    check(accepts("a%2E%2e"), "a.. is a name");
    check(!accepts("x/%2E./y"), "mixed dot segment");

    check(accepts("a/.b/..c/..."), "dots inside names");
    check(accepts("caf%C3%A9"), "encoded letters");
    check(accepts("a+b"), "plus");
    check(accepts("a.b/c..d"), "dots between letters");

    let max_tail = repeated('x', 1024);
    let long_tail = repeated('x', 1025);
    check(accepts(max_tail), "1024-byte tail");
    check(!accepts(long_tail), "1025-byte tail");
    let max_name = repeated('n', 32);
    let long_name = repeated('n', 33);
    var c2 = gweb::new_ctx(0, -1);
    check(gweb::set_rest(c2, max_name, "a"), "32-byte name");
    check_eq(gweb::param(c2, max_name), "a", "32-byte name resolves");
    check(!gweb::set_rest(c2, long_name, "a"), "33-byte name");

    var out: u8[>..] = [];
    check(gweb::path_decode(out, "a%20b"), "decode space");
    check_eq(out, "a b", "decoded space");
    out.clear();
    check(gweb::path_decode(out, "a+b"), "decode plus");
    check_eq(out, "a+b", "plus stays");
    out.clear();
    check(gweb::path_decode(out, "caf%C3%A9"), "decode utf-8");
    check(out.len == 5, "utf-8 is 5 bytes");
    out.clear();
    check(gweb::path_decode(out, ""), "decode empty");
    check(out.len == 0, "empty stays empty");
    check(gweb::path_decode(out, "a/b"), "decode slashes");
    check_eq(out, "a/b", "slashes stay");
    out.clear();
    out.append("keep:");
    check(!gweb::path_decode(out, "ok%2Fbad"), "decode refuses %2F");
    check(!gweb::path_decode(out, "ok/%zz"), "decode refuses bad escape");
    check(!gweb::path_decode(out, "ok/%2e%2E"), "decode refuses dot segment");
    check_eq(out, "keep:", "nothing appended on refusal");

    print(checks - failures, " of ", checks, " checks pass");
    if failures > 0 { exit(1); }
}
