// Operations helpers (DESIGN-ADDENDUM-16), without sockets: log line shapes, request ids, route names, flags.
// Run it with PORT, WEB_WORKERS and the GWEB_* variables unset.
//   goose build test/ops_unit.goose && test/ops_unit
import web from "..";
import web.ops;
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

let T32 = "0123456789abcdef0123456789abcdef";
let S16 = "0123456789abcdef";

// The line from the first `","level"` on: the timestamp before it changes.
fn after_ts(line: const u8[:]) -> const u8[:] {
    check(starts_with(line, "{\"ts\":\""), "json line starts with ts");
    let i = find(line, "\",\"level\"");
    check(i > 0, "json line has level");
    return if i > 0 { line[i..] } else { line };
}

fn ends(s: const u8[:], tail: const u8[:]) -> bool { s.len >= tail.len && s[s.len - tail.len..] == tail }

fn rendered(e: const web::LogEvent&) -> u8[>..] {
    var out: u8[>..] = [];
    web::render(e, out);
    return out;
}

fn test_escape() {
    var raw: u8[>..] = [];
    raw.append("a\"b\\c");
    raw.push(1 as u8);
    raw.push('\n');
    raw.push(195 as u8);
    raw.push(169 as u8);
    var out: u8[>..] = [];
    web::json_escape(out, raw);
    var want: u8[>..] = [];
    want.append("a\\\"b\\\\c\\u0001\\u000A");
    want.push(195 as u8);
    want.push(169 as u8);
    check_eq(out, want, "json_escape: quote, backslash, control bytes; non-ASCII passes through");

    var cut: u8[>..] = [];
    check(!web::json_escape_max(cut, "abcdef", 4), "json_escape_max stops");
    check_eq(cut, "abcd", "json_escape_max keeps what fits");
    var cut2: u8[>..] = [];
    check(!web::json_escape_max(cut2, "ab\ncd", 4), "json_escape_max never cuts an escape");
    check_eq(cut2, "ab", "json_escape_max stops before a \\u00XX that does not fit");
    var whole: u8[>..] = [];
    check(web::json_escape_max(whole, "abcd", 4), "json_escape_max: exact fit");
}

fn test_request_id() {
    check(web::request_id_valid("a"), "one byte");
    check(web::request_id_valid("Req-1_x.y"), "letters digits . _ -");
    check(web::request_id_valid("0123456789012345678901234567890123456789012345678901234567890123"), "64 bytes");
    check(!web::request_id_valid("01234567890123456789012345678901234567890123456789012345678901234"), "65 bytes");
    check(!web::request_id_valid(""), "empty");
    check(!web::request_id_valid("a b"), "space");
    check(!web::request_id_valid("a/b"), "slash");
    check(!web::request_id_valid("a\"b"), "quote");
    check(!web::request_id_valid("a\nb"), "newline");
    var accent: u8[>..] = [];
    accent.append("caf");
    accent.push(195 as u8);
    accent.push(169 as u8);
    check(!web::request_id_valid(accent), "non-ASCII");
}

fn test_routes() {
    let routes = "/\n/users/[id]\n/files/[...path]";
    check_eq(web::route_name(routes, 0), "/", "route 0");
    check_eq(web::route_name(routes, 1), "/users/[id]", "route 1");
    check_eq(web::route_name(routes, 2), "/files/[...path]", "last route");
    check_eq(web::route_name(routes, 3), "", "past the end");
    check_eq(web::route_name(routes, -1), "", "no route");
    check_eq(web::route_name("", 0), "", "no routes");
    check(web::method_index(http::Method.Get) == 0 && web::method_index(http::Method.Head) == 1 && web::method_index(http::Method.Other) == 7, "method order");
}

fn test_log_text() {
    web::log_configure(web::Level.Debug, false);
    var ctx = web::new_ctx(0, -1);
    ctx.request_id.append("req-1");
    var e = web::log(ctx, web::Level.Info, "order placed");
    let id: i64 = 42;
    let ratio: f64 = 2.5;
    web::field(e, "order_id", id);
    web::field(e, "note", "two words");
    web::field(e, "eq", "a=b");
    web::field(e, "quote", "say \"hi\"");
    web::field(e, "plain", "x\\y");
    web::field(e, "ok", true);
    web::field(e, "empty", "");
    web::field(e, "ratio", ratio);
    let line = rendered(e);
    check(starts_with(line, "info order placed request_id=req-1 order_id=42 note=\"two words\" eq=\"a=b\" quote=\"say \\\"hi\\\"\" plain=x\\y ok=true empty=\"\" ratio="), "text line shape");
    check(!e.truncated, "text line not truncated");

    let e2 = web::log(ctx, web::Level.Warn, "say \"hi\"");
    check_eq(rendered(e2), "warn say \"hi\" request_id=req-1", "text message is not quoted");

    var raw: u8[>..] = [];
    raw.append("a");
    raw.push('\n');
    raw.append("b");
    let blank = web::new_ctx(0, -1);
    let e3 = web::log(blank, web::Level.Error, raw);
    check_eq(rendered(e3), "error a b", "a control byte in a text message becomes a space");

    var traced = web::new_ctx(0, -1);
    traced.trace_id.append(T32);
    traced.span_id.append(S16);
    let e4 = web::log(traced, web::Level.Debug, "m");
    check_eq(rendered(e4), "debug m trace_id=0123456789abcdef0123456789abcdef span_id=0123456789abcdef", "trace ids from ctx");

    var job = web::new_ctx(-1, -1);
    job.job_id = 7;
    job.attempt = 2;
    let e5 = web::log(job, web::Level.Warn, "job attempt failed");
    check_eq(rendered(e5), "warn job attempt failed job_id=7 attempt=2", "job id and attempt from ctx");
}

fn test_log_json() {
    web::log_configure(web::Level.Debug, true);
    var ctx = web::new_ctx(0, -1);
    ctx.request_id.append("req-1");
    var e = web::log(ctx, web::Level.Info, "order \"placed\"");
    let id: i64 = 42;
    let zero: f64 = 0.0;
    let nan = zero / zero;
    web::field(e, "order_id", id);
    web::field(e, "note", "two words");
    web::field(e, "quote", "say \"hi\" \\ done");
    web::field(e, "ok", false);
    web::field(e, "nan", nan);
    web::field(e, "empty", "");
    let line = rendered(e);
    let rest = after_ts(line);
    check_eq(rest, "\",\"level\":\"info\",\"msg\":\"order \\\"placed\\\"\",\"request_id\":\"req-1\",\"order_id\":42,\"note\":\"two words\",\"quote\":\"say \\\"hi\\\" \\\\ done\",\"ok\":false,\"nan\":null,\"empty\":\"\"}", "json line shape");

    let ratio: f64 = 2.5;
    var e1 = web::log(ctx, web::Level.Info, "r");
    web::field(e1, "ratio", ratio);
    check(find(rendered(e1), "\"ratio\":") >= 0, "json float field");

    var raw: u8[>..] = [];
    raw.push(2 as u8);
    raw.append("x");
    let blank = web::new_ctx(0, -1);
    let e2 = web::log(blank, web::Level.Error, raw);
    check_eq(after_ts(rendered(e2)), "\",\"level\":\"error\",\"msg\":\"\\u0002x\"}", "control byte in a json message");

    var traced = web::new_ctx(0, -1);
    traced.trace_id.append(T32);
    traced.span_id.append(S16);
    let e3 = web::log(traced, web::Level.Info, "m");
    check_eq(after_ts(rendered(e3)), "\",\"level\":\"info\",\"msg\":\"m\",\"trace_id\":\"0123456789abcdef0123456789abcdef\",\"span_id\":\"0123456789abcdef\"}", "json trace ids");
}

fn test_truncation() {
    let blank = web::new_ctx(0, -1);
    var big: u8[>..] = [];
    for i in 200 { big.push('x'); }
    for as_json in [false, true] {
        web::log_configure(web::Level.Info, as_json);
        var e = web::log(blank, web::Level.Info, "many");
        for k in 15 {
            var key: u8[>..] = [];
            format(key, "k", k);
            web::field(e, key, big);
        }
        check(e.truncated, "fields past the line are dropped and flagged");
        let line = rendered(e);
        check(line.len <= 2048, "the finished line fits 2048 bytes");
        check(ends(line, if as_json { ",\"truncated\":true}" } else { " truncated=true" }), "the marker closes the line");
        check(find(line, "\"k0\"") >= 0 || find(line, " k0=") >= 0, "the first fields are kept");
    }

    var long: u8[>..] = [];
    for i in 3000 { long.push('a'); }
    for as_json in [false, true] {
        web::log_configure(web::Level.Info, as_json);
        let e = web::log(blank, web::Level.Info, long);
        let line = rendered(e);
        check(e.truncated && line.len <= 2048, "a long message is cut");
        check(ends(line, if as_json { ",\"truncated\":true}" } else { " truncated=true" }), "a cut message is marked");
    }
}

fn test_access_line() {
    var text: u8[>..] = [];
    web::access_line(text, false, 2, "GET", "/x?y=1", "/users/[id]", http::Status.Ok, 42, 5, "r-1", "", "");
    check_eq(text, "[2] GET /x?y=1 -> 200 OK 42us", "text access line");

    var js: u8[>..] = [];
    web::access_line(js, true, 2, "GET", "/x?y=\"1\"", "/users/[id]", http::Status.NotFound, 42, 5, "r-1", T32, S16);
    check_eq(after_ts(js), "\",\"level\":\"info\",\"msg\":\"request\",\"method\":\"GET\",\"target\":\"/x?y=\\\"1\\\"\",\"route\":\"/users/[id]\",\"status\":404,\"dur_us\":42,\"bytes\":5,\"worker\":2,\"request_id\":\"r-1\",\"trace_id\":\"0123456789abcdef0123456789abcdef\",\"span_id\":\"0123456789abcdef\"}", "json access line with trace");

    var bare: u8[>..] = [];
    web::access_line(bare, true, 0, "POST", "/", "", http::Status.Ok, 1, 0, "", "", "");
    check_eq(after_ts(bare), "\",\"level\":\"info\",\"msg\":\"request\",\"method\":\"POST\",\"target\":\"/\",\"route\":\"-\",\"status\":200,\"dur_us\":1,\"bytes\":0,\"worker\":0}", "json access line without ids");
}

fn test_config() {
    let d = web::config_from(["server"]);
    check(d.drain_ms == 10000 && d.drain_delay_ms == 0, "default drain");
    check_eq(d.log_format, "text", "default log format");
    check_eq(d.log_level, "info", "default log level");
    check(!d.metrics && !d.probe && d.schedule && !d.log, "default switches");
    check(d.job_runners == 1 && d.job_queue == 10000 && d.job_attempts == 5, "default job settings");

    let c = web::config_from(["server", "--drain-ms", "250", "--drain-delay-ms", "1000", "--log-format", "json",
                              "--log-level", "debug", "--metrics", "--job-runners", "3", "--job-queue", "50",
                              "--job-attempts", "2", "--no-schedule", "--probe", "--port", "8080", "--log"]);
    check(c.drain_ms == 250, "--drain-ms");
    check(c.drain_delay_ms == 1000, "--drain-delay-ms");
    check_eq(c.log_format, "json", "--log-format json");
    check_eq(c.log_level, "debug", "--log-level debug");
    check(c.metrics, "--metrics");
    check(c.job_runners == 3, "--job-runners");
    check(c.job_queue == 50, "--job-queue");
    check(c.job_attempts == 2, "--job-attempts");
    check(!c.schedule, "--no-schedule");
    check(c.probe, "--probe");
    check(c.port == 8080 && c.log, "older flags still parse beside the new ones");

    let z = web::config_from(["server", "--drain-ms", "0", "--job-runners", "0", "--log-level", "error", "--log-format", "text"]);
    check(z.drain_ms == 0 && z.job_runners == 0, "zero drain and no runners are allowed");
    check_eq(z.log_level, "error", "--log-level error");
    check_eq(z.log_format, "text", "--log-format text");
    let w = web::config_from(["server", "--log-level", "warn"]);
    check_eq(w.log_level, "warn", "--log-level warn");
}

fn main() {
    test_escape();
    test_request_id();
    test_routes();
    test_log_text();
    test_log_json();
    test_truncation();
    test_access_line();
    test_config();
    print(checks, " checks, ", failures, " failures");
    exit(if failures == 0 { 0 } else { 1 });
}
