// Part of gweb. Import with `import gweb.site.errors;`.
// Error pages and crash replies (DESIGN-ADDENDUM-14, D10 to D13). The generated error_reply and crash_reply call these.

namespace gweb;

import std;
import net;
import net.http;
import gweb;
import site.template;

struct ErrorInfo {
    status: i64,
    message: u8[..512],    // gweb::fail's message; "Internal Server Error" for a crash
    id: u8[..16],          // 8 random bytes in hex, also in the server log line
    crashed: bool,
    detail: u8[..4096]     // dev only: the abort text and source lines; "" in production
}

extern fn c_err_entropy(buf: u8[:]) -> i32 = "gweb_entropy";

extern fn c_if_init(n: i64, dev: i32) = "gweb_inflight_init";
extern fn c_if_dev() -> i32 = "gweb_inflight_dev";
extern fn c_if_loop(slot: i64) -> u64 = "gweb_inflight_loop";
extern fn c_if_set_route(slot: i64, route: i64) = "gweb_inflight_set_route";
extern fn c_if_get_route(slot: i64) -> i64 = "gweb_inflight_get_route";
extern fn c_if_set_phase(slot: i64, phase: i64) = "gweb_inflight_set_phase";
extern fn c_if_get_phase(slot: i64) -> i64 = "gweb_inflight_get_phase";
extern fn c_if_fd(slot: i64) -> i32 = "gweb_inflight_fd";
extern fn c_if_pending(slot: i64) -> i32 = "gweb_inflight_pending";
extern fn c_if_set_why(slot: i64, why: const u8[:]) = "gweb_inflight_set_why";
extern fn c_if_take_head(slot: i64, out: u8[>..]&) -> i64 = "gweb_inflight_take_head";
extern fn c_if_take_why(slot: i64, out: u8[>..]&) -> i64 = "gweb_inflight_take_why";
extern fn c_if_plain_500(fd: i32) = "gweb_inflight_plain_500";

let ERROR_ID_HEX = "0123456789abcdef";

// ---------------------------------------------------------------- deliberate errors

// A page or route calls this and returns: the generated finish answers with the nearest error.html (a page)
// or a JSON body (a route). A status outside 400 to 599 becomes 500. The message is cut at 512 bytes.
fn fail(ctx: Ctx&, status: i64, message: const u8[:]) {
    ctx.outcome = Outcome.Error;
    ctx.error_status = if status >= 400 && status <= 599 { status } else { 500 };
    ctx.error_message.clear();
    ctx.error_message.append(message[..min(message.len, 512)]);
}

// 16 lowercase hex digits from 8 random bytes; zeros when the system has no entropy.
fn append_id(id: u8[..16]&) {
    var raw: u8[..8] = [0; 8];
    if c_err_entropy(raw) != 0 {
        for b in raw {
            id.push(ERROR_ID_HEX[(b >> 4) as i64]);
            id.push(ERROR_ID_HEX[(b & 15) as i64]);
        }
    } else {
        id.append("0000000000000000");
    }
}

fn new_error(status: i64, message: const u8[:], crashed: bool) -> ErrorInfo {
    var e = ErrorInfo { status: status, message: "", id: "", crashed: crashed, detail: "" };
    e.message.append(message[..min(message.len, 512)]);
    append_id(e.id);
    return e;
}

// gweb: error <id>: <status> <method> <target>: <text>
fn log_error(e: const ErrorInfo&, req: const http::Request&, text: const u8[:]) {
    print("gweb: error ", e.id, ": ", e.status, " ", req.method_text, " ", req.target, ": ", text);
}

// ---------------------------------------------------------------- replies

// The page used when no error.html applies: <h1>500 Internal Server Error</h1> and the id.
fn builtin_page(out: u8[>..]&, e: const ErrorInfo&) {
    let reason = http::reason(http::status_from_code(e.status));
    out.append("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>");
    format(out, e.status, " ", reason);
    out.append("</title></head><body><h1>");
    format(out, e.status, " ", reason);
    out.append("</h1>");
    if !e.crashed && e.message.len > 0 { out.append("<p>"); escape(out, e.message); out.append("</p>"); }
    out.append("<p>Error id: <code>");
    out.append(e.id);
    out.append("</code></p></body></html>");
}

// {"error":"<message>","id":"<id>"} with the error's status.
fn error_json(res: http::Response&, e: const ErrorInfo&) {
    http::json_reply(res, http::status_from_code(e.status));
    res.body.clear();
    res.body.append("{\"error\":");
    json_quoted(res.body, e.message, false);
    res.body.append(",\"id\":");
    json_quoted(res.body, e.id, false);
    res.body.push('}');
}

// Starts an HTML error reply: status set, content type html, headers and body empty.
fn error_start(res: http::Response&, e: const ErrorInfo&) {
    res.headers.clear();
    res.body.clear();
    html(res, http::status_from_code(e.status));
}

// Dev only: the detail for the overlay, JSON-escaped and <-safe, in the tag the dev script reads.
fn dev_error_script(out: u8[>..]&, e: const ErrorInfo&) {
    out.append("<script type=\"application/json\" id=\"gw-dev-error\">");
    json_text(out, e.detail);
    out.append("</script>");
}

// ---------------------------------------------------------------- dev detail (D13)

// The lines of s as slices (gweb::split is the router's, so std's is out of reach here).
fn split_lines(s: const u8[:], sep: u8) -> const u8[:][>..] {
    var out: const u8[:][>..] = [];
    var start = 0;
    for c, i in s {
        if c == sep {
            out.push(s[start..i]);
            start = i + 1;
        }
    }
    out.push(s[start..]);
    return out;
}

fn path_stop(c: u8) -> bool {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '"' || c == '\'' || c == '(' || c == ')'
        || c == '<' || c == '>' || c == '[' || c == ']' || c == ',' || c == '=';
}

// The source file of a generated file name in .gooseweb/map.txt ("gen.goose<TAB>source"); "" when absent.
fn map_source(map: const u8[:], base: const u8[:]) -> const u8[:] {
    for line in split_lines(map, '\n') {
        let name, path, ok = split_once(line, '\t');
        if ok && name == base { return path; }
    }
    return "";
}

// Appends the source path, the line and the lines around it (the line itself marked >) for a location in a generated file.
// Page, layout and page.goose files map line for line. A component file maps through the `// gw:line N` tag on the
// generated line, as the CLI's component_lines_back does. False when the file is not one of the app's.
fn add_excerpt(d: u8[>..]&, gen_path: const u8[:], gen_line: i64, map: const u8[:], seen: u8[>..]&) -> bool {
    let slash = rfind(gen_path, "/");
    let base = if slash >= 0 { gen_path[slash + 1..] } else { gen_path };
    var src: u8[>..] = [];
    let mapped = map_source(map, base);
    if mapped.len > 0 {
        src.append(mapped);
    } else {
        let lib = find(gen_path, ".gooseweb/lib/");
        if lib < 0 { return false; }
        src.append("lib/");
        src.append(gen_path[lib + 14..]);
    }
    var line = gen_line;
    if starts_with(src, "components/") {
        line = -1;
        var g: u8[>..] = [];
        format(g, ".gooseweb/", base);
        var code: u8[>..] = [];
        if read_file(g, code) {
            let ls = split_lines(code, '\n');
            if gen_line >= 1 && gen_line - 1 < ls.len {
                let tag = find(ls[gen_line - 1], "// gw:line ");
                if tag >= 0 {
                    let v, ok = parse_int(trim(ls[gen_line - 1][tag + 11..]));
                    if ok { line = v; }
                }
            }
        }
        if line < 1 {
            format(d, "\n", src, " (generated code)\n");
            return true;
        }
    }
    var key: u8[>..] = [];
    format(key, src, ":", line, " ");
    if find(seen, key) >= 0 { return false; }
    seen.append(key);
    format(d, "\n", src, ":", line, "\n");
    var text: u8[>..] = [];
    if read_file(src, text) {
        let ls = split_lines(text, '\n');
        let from = max(1, line - 2);
        let to = min(ls.len, line + 2);
        var n = from;
        while n <= to {
            if n == line { d.append("> "); } else { d.append("  "); }
            format(d, n, " | ", ls[n - 1], "\n");
            n += 1;
        }
    }
    return true;
}

// Looks for up to 3 path:line locations of generated .goose files in the abort text.
fn add_excerpts(d: u8[>..]&, text: const u8[:], map: const u8[:]) {
    var found = 0;
    var seen: u8[>..] = [];
    var pos = 0;
    while pos < text.len && found < 3 {
        let k = find(text[pos..], ".goose:");
        if k < 0 { break; }
        let colon = pos + k + 6;
        var s = pos + k;
        while s > 0 && !path_stop(text[s - 1]) { s -= 1; }
        var e = colon + 1;
        while e < text.len && text[e] >= '0' && text[e] <= '9' { e += 1; }
        pos = e;
        if e == colon + 1 { continue; }
        let line, ok = parse_int(text[colon + 1..e]);
        if !ok || line < 1 { continue; }
        if add_excerpt(d, text[s..colon], line, map, seen) { found += 1; }
    }
}

// Fills e.detail: method and target; the abort text (a crash) or the message (gweb::fail); then source lines for the
// locations in the abort text. Capped at e.detail's capacity. Call only in dev; production leaves detail "".
fn dev_detail(e: ErrorInfo&, req: const http::Request&, abort_text: const u8[:]) {
    var d: u8[>..] = [];
    format(d, req.method_text, " ", req.target, "\n");
    if abort_text.len > 0 {
        format(d, "\n", abort_text, "\n");
        var map: u8[>..] = [];
        if read_file(".gooseweb/map.txt", map) { add_excerpts(d, abort_text, map); }
    } else if e.message.len > 0 {
        format(d, "\n", e.message, "\n");
    }
    e.detail.clear();
    e.detail.append(d[..min(d.len, e.detail.cap)]);
}

// ---------------------------------------------------------------- crash helpers (D12)

// Call once in main before any worker starts. dev is stored in C, where every worker thread reads it.
fn inflight_init(workers: i64, dev: bool) { c_if_init(workers, if dev { 1 } else { 0 }); }

// True when the server runs under gweb dev (--dev-id): error pages carry the detail.
fn dev_mode() -> bool { return c_if_dev() != 0; }

// The dispatcher calls this beside ctx.route = i.
fn inflight_route(slot: i64, route: i64) { c_if_set_route(slot, route); }

// 1 while an error page renders after gweb::fail: a crash then starts at attempt 2.
fn inflight_phase(slot: i64, phase: i64) { c_if_set_phase(slot, phase); }

fn inflight_route_of(slot: i64) -> i64 { return c_if_get_route(slot); }
fn inflight_phase_of(slot: i64) -> i64 { return c_if_get_phase(slot); }
fn inflight_pending(slot: i64) -> bool { return c_if_pending(slot) != 0; }
fn inflight_set_why(slot: i64, why: const u8[:]) { c_if_set_why(slot, why); }
fn inflight_conn(slot: i64) -> net::Socket { return net::Socket { fd: c_if_fd(slot) }; }

// Appends the saved head plus CRLF CRLF to head (so http::parse_request takes it) and the abort text to why.
// The caller owns both builders and keeps them alive as long as the Request it parses from head.
fn crash_info(slot: i64, head: u8[>..]&, why: u8[>..]&) {
    c_if_take_head(slot, head);
    head.append("\r\n\r\n");
    c_if_take_why(slot, why);
}

// The last resort: a fixed 500 straight to the connection.
fn plain_500(slot: i64) { c_if_plain_500(c_if_fd(slot)); }

// After the answer: frees the dead worker's loop, which closes its connections, and clears the slot.
fn inflight_release(slot: i64) {
    let h = c_if_loop(slot);
    if h != 0 { net::free(net::Loop { handle: h }); }
    c_if_set_loop(slot, 0);
    c_if_end(slot);
}
