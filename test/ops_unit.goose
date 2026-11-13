// Operations helpers (DESIGN-ADDENDUM-16), without sockets: log line shapes, request ids, route names, flags.
// Run it with PORT, GWEB_WORKERS and the GWEB_* variables unset.
//   goose build test/ops_unit.goose && test/ops_unit
import gweb from "..";
import gweb.ops.log;
import gweb.ops.jobs;
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

fn rendered(e: const gweb::LogEvent&) -> u8[>..] {
    var out: u8[>..] = [];
    gweb::log_render(e, out);
    return out;
}

fn test_escape() {
    var raw: u8[>..] = [];
    raw.append("a\"b\\c");
    raw.push(1);
    raw.push('\n');
    raw.push(195);
    raw.push(169);
    var out: u8[>..] = [];
    gweb::json_escape(out, raw);
    var want: u8[>..] = [];
    want.append("a\\\"b\\\\c\\u0001\\u000A");
    want.push(195);
    want.push(169);
    check_eq(out, want, "json_escape: quote, backslash, control bytes; non-ASCII passes through");

    var cut: u8[>..] = [];
    check(!gweb::_json_escape_max(cut, "abcdef", 4), "json_escape_max stops");
    check_eq(cut, "abcd", "json_escape_max keeps what fits");
    var cut2: u8[>..] = [];
    check(!gweb::_json_escape_max(cut2, "ab\ncd", 4), "json_escape_max never cuts an escape");
    check_eq(cut2, "ab", "json_escape_max stops before a \\u00XX that does not fit");
    var whole: u8[>..] = [];
    check(gweb::_json_escape_max(whole, "abcd", 4), "json_escape_max: exact fit");
}

fn test_request_id() {
    check(gweb::_request_id_valid("a"), "one byte");
    check(gweb::_request_id_valid("Req-1_x.y"), "letters digits . _ -");
    check(gweb::_request_id_valid("0123456789012345678901234567890123456789012345678901234567890123"), "64 bytes");
    check(!gweb::_request_id_valid("01234567890123456789012345678901234567890123456789012345678901234"), "65 bytes");
    check(!gweb::_request_id_valid(""), "empty");
    check(!gweb::_request_id_valid("a b"), "space");
    check(!gweb::_request_id_valid("a/b"), "slash");
    check(!gweb::_request_id_valid("a\"b"), "quote");
    check(!gweb::_request_id_valid("a\nb"), "newline");
    var accent: u8[>..] = [];
    accent.append("caf");
    accent.push(195);
    accent.push(169);
    check(!gweb::_request_id_valid(accent), "non-ASCII");
}

fn test_routes() {
    let routes = "/\n/users/[id]\n/files/[...path]";
    check_eq(gweb::_route_name(routes, 0), "/", "route 0");
    check_eq(gweb::_route_name(routes, 1), "/users/[id]", "route 1");
    check_eq(gweb::_route_name(routes, 2), "/files/[...path]", "last route");
    check_eq(gweb::_route_name(routes, 3), "", "past the end");
    check_eq(gweb::_route_name(routes, -1), "", "no route");
    check_eq(gweb::_route_name("", 0), "", "no routes");
    check(gweb::_method_index(http::Method.Get) == 0 && gweb::_method_index(http::Method.Head) == 1 && gweb::_method_index(http::Method.Other) == 7, "method order");
}

fn test_log_text() {
    gweb::_log_configure(gweb::Level.Debug, false);
    var ctx = gweb::_new_ctx(0, -1);
    ctx.request_id.append("req-1");
    var e = gweb::log_event(ctx, gweb::Level.Info, "order placed");
    let id: i64 = 42;
    let ratio: f64 = 2.5;
    gweb::log_field(e, "order_id", id);
    gweb::log_field(e, "note", "two words");
    gweb::log_field(e, "eq", "a=b");
    gweb::log_field(e, "quote", "say \"hi\"");
    gweb::log_field(e, "plain", "x\\y");
    gweb::log_field(e, "ok", true);
    gweb::log_field(e, "empty", "");
    gweb::log_field(e, "ratio", ratio);
    let line = rendered(e);
    check(starts_with(line, "info order placed request_id=req-1 order_id=42 note=\"two words\" eq=\"a=b\" quote=\"say \\\"hi\\\"\" plain=x\\y ok=true empty=\"\" ratio="), "text line shape");
    check(!e.truncated, "text line not truncated");

    let e2 = gweb::log_event(ctx, gweb::Level.Warn, "say \"hi\"");
    check_eq(rendered(e2), "warn say \"hi\" request_id=req-1", "text message is not quoted");

    var raw: u8[>..] = [];
    raw.append("a");
    raw.push('\n');
    raw.append("b");
    let blank = gweb::_new_ctx(0, -1);
    let e3 = gweb::log_event(blank, gweb::Level.Error, raw);
    check_eq(rendered(e3), "error a b", "a control byte in a text message becomes a space");

    var traced = gweb::_new_ctx(0, -1);
    traced.trace_id.append(T32);
    traced.span_id.append(S16);
    let e4 = gweb::log_event(traced, gweb::Level.Debug, "m");
    check_eq(rendered(e4), "debug m trace_id=0123456789abcdef0123456789abcdef span_id=0123456789abcdef", "trace ids from ctx");

    var job = gweb::_new_ctx(-1, -1);
    job.job_id = 7;
    job.attempt = 2;
    let e5 = gweb::log_event(job, gweb::Level.Warn, "job attempt failed");
    check_eq(rendered(e5), "warn job attempt failed job_id=7 attempt=2", "job id and attempt from ctx");
}

fn test_log_json() {
    gweb::_log_configure(gweb::Level.Debug, true);
    var ctx = gweb::_new_ctx(0, -1);
    ctx.request_id.append("req-1");
    var e = gweb::log_event(ctx, gweb::Level.Info, "order \"placed\"");
    let id: i64 = 42;
    let zero: f64 = 0.0;
    let nan = zero / zero;
    gweb::log_field(e, "order_id", id);
    gweb::log_field(e, "note", "two words");
    gweb::log_field(e, "quote", "say \"hi\" \\ done");
    gweb::log_field(e, "ok", false);
    gweb::log_field(e, "nan", nan);
    gweb::log_field(e, "empty", "");
    let line = rendered(e);
    let rest = after_ts(line);
    check_eq(rest, "\",\"level\":\"info\",\"msg\":\"order \\\"placed\\\"\",\"request_id\":\"req-1\",\"order_id\":42,\"note\":\"two words\",\"quote\":\"say \\\"hi\\\" \\\\ done\",\"ok\":false,\"nan\":null,\"empty\":\"\"}", "json line shape");

    let ratio: f64 = 2.5;
    var e1 = gweb::log_event(ctx, gweb::Level.Info, "r");
    gweb::log_field(e1, "ratio", ratio);
    check(find(rendered(e1), "\"ratio\":") >= 0, "json float field");

    var raw: u8[>..] = [];
    raw.push(2);
    raw.append("x");
    let blank = gweb::_new_ctx(0, -1);
    let e2 = gweb::log_event(blank, gweb::Level.Error, raw);
    check_eq(after_ts(rendered(e2)), "\",\"level\":\"error\",\"msg\":\"\\u0002x\"}", "control byte in a json message");

    var traced = gweb::_new_ctx(0, -1);
    traced.trace_id.append(T32);
    traced.span_id.append(S16);
    let e3 = gweb::log_event(traced, gweb::Level.Info, "m");
    check_eq(after_ts(rendered(e3)), "\",\"level\":\"info\",\"msg\":\"m\",\"trace_id\":\"0123456789abcdef0123456789abcdef\",\"span_id\":\"0123456789abcdef\"}", "json trace ids");
}

fn test_truncation() {
    let blank = gweb::_new_ctx(0, -1);
    var big: u8[>..] = [];
    for i in 200 { big.push('x'); }
    for as_json in [false, true] {
        gweb::_log_configure(gweb::Level.Info, as_json);
        var e = gweb::log_event(blank, gweb::Level.Info, "many");
        for k in 15 {
            var key: u8[>..] = [];
            format(key, "k", k);
            gweb::log_field(e, key, big);
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
        gweb::_log_configure(gweb::Level.Info, as_json);
        let e = gweb::log_event(blank, gweb::Level.Info, long);
        let line = rendered(e);
        check(e.truncated && line.len <= 2048, "a long message is cut");
        check(ends(line, if as_json { ",\"truncated\":true}" } else { " truncated=true" }), "a cut message is marked");
    }
}

fn test_access_line() {
    var text: u8[>..] = [];
    gweb::_access_line(text, false, 2, "GET", "/x?y=1", "/users/[id]", http::Status.Ok, 42, 5, "r-1", "", "");
    check_eq(text, "[2] GET /x?y=1 -> 200 OK 42us", "text access line");

    var js: u8[>..] = [];
    gweb::_access_line(js, true, 2, "GET", "/x?y=\"1\"", "/users/[id]", http::Status.NotFound, 42, 5, "r-1", T32, S16);
    check_eq(after_ts(js), "\",\"level\":\"info\",\"msg\":\"request\",\"method\":\"GET\",\"target\":\"/x?y=\\\"1\\\"\",\"route\":\"/users/[id]\",\"status\":404,\"dur_us\":42,\"bytes\":5,\"worker\":2,\"request_id\":\"r-1\",\"trace_id\":\"0123456789abcdef0123456789abcdef\",\"span_id\":\"0123456789abcdef\"}", "json access line with trace");

    var bare: u8[>..] = [];
    gweb::_access_line(bare, true, 0, "POST", "/", "", http::Status.Ok, 1, 0, "", "", "");
    check_eq(after_ts(bare), "\",\"level\":\"info\",\"msg\":\"request\",\"method\":\"POST\",\"target\":\"/\",\"route\":\"-\",\"status\":200,\"dur_us\":1,\"bytes\":0,\"worker\":0}", "json access line without ids");
}

fn test_config() {
    let d = gweb::_config_from(["server"]);
    check(d.drain_ms == 10000 && d.drain_delay_ms == 0, "default drain");
    check_eq(d.log_format, "text", "default log format");
    check_eq(d.log_level, "info", "default log level");
    check(!d.metrics && !d.probe && d.schedule && !d.access_log, "default switches");
    check(d.job_runners == 1 && d.job_queue == 10000 && d.job_attempts == 5, "default job settings");

    let c = gweb::_config_from(["server", "--drain-ms", "250", "--drain-delay-ms", "1000", "--log-format", "json",
                              "--log-level", "debug", "--metrics", "--job-runners", "3", "--job-queue", "50",
                              "--job-attempts", "2", "--no-schedule", "--probe", "--port", "8080", "--access-log"]);
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
    check(c.port == 8080 && c.access_log, "older flags still parse beside the new ones");

    let z = gweb::_config_from(["server", "--drain-ms", "0", "--job-runners", "0", "--log-level", "error", "--log-format", "text"]);
    check(z.drain_ms == 0 && z.job_runners == 0, "zero drain and no runners are allowed");
    check_eq(z.log_level, "error", "--log-level error");
    check_eq(z.log_format, "text", "--log-format text");
    let w = gweb::_config_from(["server", "--log-level", "warn"]);
    check_eq(w.log_level, "warn", "--log-level warn");
}

// The flag parser takes err instead of exiting, so every refusal can be checked here. The variables are checked in
// test/config.sh, which starts the real server: setenv cannot overwrite a value in this process.
fn parse_err(flags: const u8[:][:]) -> u8[>..] {
    var a: (const u8[:])[>..] = [];
    a.push("server");
    for f in flags { a.push(f); }
    var cfg = gweb::_default_config();
    var err: u8[>..] = [];
    if gweb::_config_parse(a, cfg, err) { err.append("ok"); }
    return err;
}

fn parse_cfg(flags: const u8[:][:]) -> gweb::Config {
    var a: (const u8[:])[>..] = [];
    a.push("server");
    for f in flags { a.push(f); }
    var cfg = gweb::_default_config();
    var err: u8[>..] = [];
    if !gweb::_config_parse(a, cfg, err) { print("parse failed: ", err); failures += 1; }
    return cfg;
}

fn test_config_rules() {
    // booleans: every spelling, on and off, as a bare flag, --no-X and --X=value
    for w in ["1", "true", "yes", "on", "TRUE", "On"] {
        var f: u8[>..] = [];
        format(f, "--metrics=", w);
        let fs: const u8[:] = f;
        check(parse_cfg([fs]).metrics, f);
    }
    for w in ["0", "false", "no", "off", "False", "OFF"] {
        var f: u8[>..] = [];
        format(f, "--schedule=", w);
        let fs: const u8[:] = f;
        check(!parse_cfg([fs]).schedule, f);
    }
    check(parse_cfg(["--trust-proxy"]).auth.trust_proxy, "--trust-proxy");
    check(!parse_cfg(["--no-security-headers"]).security_headers, "--no-security-headers");
    check(!parse_cfg(["--no-schedule"]).schedule, "--no-schedule is --schedule=0");
    check(parse_cfg(["--no-metrics"]).metrics == false, "--no-metrics");
    check(parse_cfg(["--csp"]).csp == 1 && parse_cfg(["--csp=report-only"]).csp == 2 && parse_cfg(["--csp=off"]).csp == 0, "--csp, --csp=report-only, --csp=off");
    check(parse_cfg(["--no-csp"]).csp == 0, "--no-csp");
    check_eq(parse_err(["--metrics=maybe"]), "gweb: --metrics=maybe: must be 1, 0, true, false, yes, no, on or off", "a bad boolean names the flag");
    // every setting has a flag in both forms
    let k = parse_cfg(["--port=8081", "--host", "10.0.0.5", "--workers", "3", "--idle-ms=0", "--max-body", "2048", "--max-upload=4096",
                       "--max-upload-parts", "10", "--max-upload-files", "16", "--max-upload-text=1000", "--upload-dir", "/tmp/up",
                       "--hsts", "60", "--session-idle", "100", "--session-max=200", "--access-log"]);
    check(k.port == 8081 && k.workers == 3 && k.idle_ms == 0 && k.max_body == 2048 && k.max_upload == 4096, "ints in both forms");
    check_eq(k.host, "10.0.0.5", "--host");
    check(k.upload_parts == 10 && k.upload_files == 16 && k.upload_text == 1000, "the multipart limits");
    check_eq(k.upload_dir, "/tmp/up", "--upload-dir");
    check(k.hsts == 60 && k.auth.idle == 100 && k.auth.max == 200 && k.access_log, "--hsts, session lifetimes and --access-log");
    // ranges
    check_eq(parse_err(["--port", "0"]), "gweb: --port 0: must be a whole number from 1 to 65535", "--port 0");
    check_eq(parse_err(["--port", "65536"]), "gweb: --port 65536: must be a whole number from 1 to 65535", "--port 65536");
    check_eq(parse_err(["--port=-1"]), "gweb: --port=-1: must be a whole number from 1 to 65535", "--port=-1");
    check_eq(parse_err(["--port", "abc"]), "gweb: --port abc: must be a whole number from 1 to 65535", "--port abc");
    check_eq(parse_err(["--port", "65535"]), "ok", "--port 65535");
    check_eq(parse_err(["--idle-ms", "-1"]), "gweb: --idle-ms -1: must be a whole number, 0 or more", "negative --idle-ms");
    check_eq(parse_err(["--max-body", "-5"]), "gweb: --max-body -5: must be a whole number, 1 or more", "negative --max-body");
    check_eq(parse_err(["--workers", "0"]), "gweb: --workers 0: must be a whole number, 1 or more", "--workers 0");
    check_eq(parse_err(["--max-upload-files", "17"]), "gweb: --max-upload-files 17: must be a whole number from 1 to 16", "--max-upload-files 17");
    check_eq(parse_err(["--log-level", "loud"]), "gweb: --log-level loud: must be debug, info, warn or error", "bad --log-level");
    check_eq(parse_err(["--log-format", "xml"]), "gweb: --log-format xml: must be text or json", "bad --log-format");
    check_eq(parse_err(["--csp=sometimes"]), "gweb: --csp=sometimes: must be 1, 0 or report-only", "bad --csp");
    // the message is true: missing value, unknown flag, a stray word, the renamed flag
    check_eq(parse_err(["--port"]), "gweb: --port needs a value", "--port at the end needs a value");
    check_eq(parse_err(["--export"]), "gweb: --export needs a value", "--export needs a value");
    check_eq(parse_err(["--frobnicate"]), "gweb: unknown flag: --frobnicate", "an unknown flag");
    check_eq(parse_err(["--no-port"]), "gweb: unknown flag: --no-port", "--no- of a setting that is not a boolean");
    check_eq(parse_err(["--no-metrics=1"]), "gweb: --no-metrics takes no value", "--no-X takes no value");
    check_eq(parse_err(["stray"]), "gweb: unexpected argument: stray", "a word that is not a flag");
    check_eq(parse_err(["--log"]), "gweb: --log is now --access-log", "--log names its replacement");
    // modes
    check(parse_cfg(["--dev-id", "5"]).dev_id == 5 && parse_cfg(["--probe"]).probe, "--dev-id and --probe");
    check_eq(parse_cfg(["--export", "out"]).export_dir, "out", "--export");
    check_eq(parse_err(["--dev-id", "x"]), "gweb: --dev-id x: must be a whole number, 0 or more", "bad --dev-id");
    // defaults are unchanged
    let d = gweb::_default_config();
    check_eq(d.host, "0.0.0.0", "the server's default host stays 0.0.0.0");
    check(d.upload_parts == 64 && d.upload_files == 8 && d.upload_text == 65536, "default multipart limits");
}

// A job's ctx carries the hub, so jobs can gweb::publish.
fn test_job_ctx() {
    let c = gweb::_job_ctx(0, -1, 7, 1, "job", 77);
    check(c.hub == 77 && c.job_id == 7 && c.worker == -1, "job_ctx carries the hub");
}

fn main() {
    test_job_ctx();
    test_escape();
    test_request_id();
    test_routes();
    test_log_text();
    test_log_json();
    test_truncation();
    test_access_line();
    test_config();
    test_config_rules();
    print(checks, " checks, ", failures, " failures");
    exit(if failures == 0 { 0 } else { 1 });
}
