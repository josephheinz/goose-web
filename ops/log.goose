// Part of gweb. Import with `import gweb.ops.log;`.
// Structured logs, app metrics and spans for handlers and jobs; ops_init and ops_shutdown start and stop the C modules.

namespace gweb;

import std;
import net;
import net.http;
import gweb;

// A log line under construction. field adds to it, emit writes it; render gives the finished line.
// line holds the head (and the fields so far) in the format in force when log made it.
struct LogEvent { line: u8[..2048], level: Level, truncated: bool, json: bool }

const LOG_RESERVE = 24;   // room kept for the closing "}" and the truncated marker

// Text values with a space, control byte, " or = (or no bytes at all) are quoted.
fn text_needs_quote(s: const u8[:]) -> bool {
    if s.len == 0 { return true; }
    for c in s { if c <= ' ' || c == 127 || c == 34 || c == '=' { return true; } }
    return false;
}

fn text_value(out: u8[>..]&, s: const u8[:]) {
    if !text_needs_quote(s) { out.append(s); return; }
    out.append("\"");
    json_escape(out, s);
    out.append("\"");
}

// A new event: "level msg" in text format, {"ts","level","msg"} in json, then request_id, trace_id and span_id
// (and job_id and attempt in a job) from ctx when set. A message too long for the line is cut and the line gets truncated.
fn log(ctx: const Ctx&, level: Level, msg: const u8[:]) -> LogEvent {
    var e = LogEvent { line: "", level: level, truncated: false, json: c_log_json() != 0 };
    let budget = e.line.cap - LOG_RESERVE - 64;
    var m: u8[>..] = [];
    if e.json {
        var ts: u8[>..] = [];
        c_rfc3339(ts);
        format(e.line, "{\"ts\":\"", ts, "\",\"level\":\"", level_name(level), "\",\"msg\":\"");
        if !json_escape_max(m, msg, budget) { e.truncated = true; }
        e.line.append(m);
        e.line.append("\"");
    } else {
        format(e.line, level_name(level), " ");
        let whole = msg.len <= budget;
        for c in msg[..min(msg.len, budget)] { m.push(if c < 32 || c == 127 { ' ' } else { c }); }
        e.truncated = !whole;
        e.line.append(m);
    }
    if ctx.request_id.len > 0 { field_text(e, "request_id", ctx.request_id); }
    if ctx.trace_id.len > 0 { field_text(e, "trace_id", ctx.trace_id); field_text(e, "span_id", ctx.span_id); }
    if ctx.job_id != 0 { field(e, "job_id", ctx.job_id); field(e, "attempt", ctx.attempt); }
    return e;
}

// Appends " key=value" or ,"key":value; frag is the value already in the format's notation. A field that does not
// fit is dropped and the event is marked truncated.
fn push_field(e: LogEvent&, key: const u8[:], frag: const u8[:]) {
    var piece: u8[>..] = [];
    if e.json {
        piece.append(",\"");
        json_escape(piece, key);
        piece.append("\":");
    } else {
        piece.push(' ');
        piece.append(key);
        piece.push('=');
    }
    piece.append(frag);
    if piece.len > e.line.cap - e.line.len - LOG_RESERVE { e.truncated = true; return; }
    e.line.append(piece);
}

fn field_text(e: LogEvent&, key: const u8[:], v: const u8[:]) {
    var frag: u8[>..] = [];
    if e.json { frag.append("\""); json_escape(frag, v); frag.append("\""); }
    else { text_value(frag, v); }
    push_field(e, key, frag);
}

fn field(e: LogEvent&, key: const u8[:], v: const u8[:]) { field_text(e, key, v); }

fn field(e: LogEvent&, key: const u8[:], v: i64) {
    var frag: u8[>..] = [];
    format(frag, v);
    push_field(e, key, frag);
}

// NaN and infinity are null in json, since json has no notation for them.
fn field(e: LogEvent&, key: const u8[:], v: f64) {
    var frag: u8[>..] = [];
    if e.json && (v != v || v - v != 0.0) { frag.append("null"); } else { format(frag, v); }
    push_field(e, key, frag);
}

fn field(e: LogEvent&, key: const u8[:], v: bool) {
    var frag: u8[>..] = [];
    frag.append(if v { "true" } else { "false" });
    push_field(e, key, frag);
}

// Appends the finished line (no newline): the fields, then truncated=true if any was dropped, then "}" in json.
fn render(e: const LogEvent&, out: u8[>..]&) {
    out.append(e.line);
    if e.truncated { out.append(if e.json { ",\"truncated\":true" } else { " truncated=true" }); }
    if e.json { out.append("}"); }
}

// Writes the event if its level is at or above the configured one.
fn emit(e: const LogEvent&) {
    var line: u8[>..] = [];
    render(e, line);
    log_write(e.level, line);
}

fn debug(ctx: const Ctx&, msg: const u8[:]) { let e = log(ctx, Level.Debug, msg); emit(e); }
fn info(ctx: const Ctx&, msg: const u8[:]) { let e = log(ctx, Level.Info, msg); emit(e); }
fn warn(ctx: const Ctx&, msg: const u8[:]) { let e = log(ctx, Level.Warn, msg); emit(e); }
fn error(ctx: const Ctx&, msg: const u8[:]) { let e = log(ctx, Level.Error, msg); emit(e); }

// An app counter, shown as gweb_<name>... in /__gweb/metrics when --metrics is on. Names are [a-z_][a-z0-9_]*.
fn count(name: const u8[:], n: i64) { c_metric_count(name, n); }

fn gauge(name: const u8[:], v: f64) { c_metric_gauge(name, v); }

// An open child span. span makes it the ctx's current span, so logs and traceparent inside it name it;
// span_end restores the parent and, for a sampled request, records it. on is false when tracing is off.
struct Span { id: u8[..16], parent: u8[..16], name: u8[..128], start_ns: i64, on: bool }

fn span(ctx: Ctx&, name: const u8[:]) -> Span {
    var s = Span { id: "", parent: "", name: "", start_ns: 0, on: false };
    if ctx.trace_id.len == 0 { return s; }
    var id: u8[>..] = [];
    c_rand_hex(id, 8);
    s.id.append(id);
    s.parent.append(ctx.span_id);
    s.name.append(name[..min(name.len, 128)]);
    s.start_ns = c_unix_ns();
    s.on = true;
    ctx.span_id.clear();
    ctx.span_id.append(s.id);
    return s;
}

fn span_end(ctx: Ctx&, s: const Span&) {
    if !s.on { return; }
    ctx.span_id.clear();
    ctx.span_id.append(s.parent);
    if ctx.sampled {
        c_span_push(ctx.trace_id, s.id, s.parent, s.name, 1, s.start_ns, c_unix_ns(), 0, "", "", "", 0, "", "", 0);
    }
}

// Appends a W3C traceparent header value naming the ctx's current span, for an outgoing call; nothing without tracing.
fn traceparent(ctx: const Ctx&, out: u8[>..]&) {
    if ctx.trace_id.len == 0 { return; }
    c_traceparent(out, ctx.trace_id, ctx.span_id, if ctx.sampled { 1 } else { 0 });
}

// Call in main, before the workers start: sets the log level and format, starts the metrics table (with --metrics;
// routes_nl is the route patterns joined by newlines) and the tracing exporter (from the OTEL_* variables).
fn ops_init(cfg: const Config&, routes_nl: const u8[:]) {
    log_configure(level_from_name(cfg.log_level), cfg.log_format == "json");
    if cfg.metrics { c_metrics_init(cfg.workers as i32, routes_nl); }
    let t = c_otel_start_from_env();
    if t == 1 { log_message(Level.Info, "goose-web: tracing on"); }
    else if t == 2 { log_message(Level.Warn, "goose-web: tracing is off: the OTLP endpoint is not usable"); }
}

// Call in main when the server has stopped: sends the queued spans, waiting up to 2 seconds.
fn ops_shutdown() {
    if c_otel_flush(2000) == 0 { log_message(Level.Warn, "goose-web: tracing export did not finish in 2 s"); }
}
