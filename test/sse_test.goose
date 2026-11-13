// SSE event formatting (DESIGN-ADDENDUM-12 section 7.9), without sockets.
//   goose build test/sse_test.goose && test/sse_test
import gweb from "..";
import net from "../../goose-net";
import std;

var failures = 0;
var checks = 0;

fn check_eq(got: const u8[:], want: const u8[:], what: const u8[:]) {
    checks += 1;
    if got != want { failures += 1; print("FAIL ", what, ": got '", got, "' want '", want, "'"); }
}

fn main() {
    var out: u8[>..] = [];
    gweb::sse_event(out, "ping", "x");
    check_eq(out, "event: ping\ndata: x\n\n", "one line");

    out.clear();
    gweb::sse_event(out, "ping", "");
    check_eq(out, "event: ping\ndata: \n\n", "empty data");

    out.clear();
    gweb::sse_event(out, "m", "a\nb\nc");
    check_eq(out, "event: m\ndata: a\ndata: b\ndata: c\n\n", "multi-line data");

    out.clear();
    gweb::sse_event(out, "m", "a\n");
    check_eq(out, "event: m\ndata: a\ndata: \n\n", "trailing newline kept as an empty data line");

    out.clear();
    gweb::sse_event(out, "m", "a\r\nb\rc");
    check_eq(out, "event: m\ndata: a\ndata: b\ndata: c\n\n", "CRLF and CR are line breaks");

    out.clear();
    gweb::sse_fragment(out, "cart", "<p>1</p>\n<p>2</p>\n");
    check_eq(out, "event: fragment\ndata: cart\ndata: <p>1</p>\ndata: <p>2</p>\ndata: \n\n", "fragment");

    out.clear();
    gweb::sse_store(out, "Cart", "{\"count\":3}");
    check_eq(out, "event: store\ndata: Cart\ndata: {\"count\":3}\n\n", "store");

    out.clear();
    gweb::sse_event(out, "a", "1");
    gweb::sse_event(out, "b", "2");
    check_eq(out, "event: a\ndata: 1\n\nevent: b\ndata: 2\n\n", "events append");

    print(checks - failures, " of ", checks, " checks pass");
    if failures > 0 { exit(1); }
}
