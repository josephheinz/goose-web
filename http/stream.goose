// Part of gweb. Import with `import gweb.http.stream;`.
// A stream holds its worker until it ends: use it for exports and downloads, and gweb::subscribe for anything that waits on events.

namespace gweb;

import std;
import net;
import net.http;
import gweb;

struct Stream { conn: net::Socket, chunked: bool, head_only: bool, ok: bool }

// Sends the head now (queued cookies included), then the handler writes the body and calls end.
// ok is false when the head could not be sent; the handler should return, and run_worker then replies as usual
// (a 500 when the cookies did not fit). res.body is ignored.
fn stream_begin(req: const http::Request&, ctx: Ctx&, res: http::Response&) -> Stream {
    var s = Stream { conn: net::Socket { fd: ctx.conn_fd }, chunked: http::supports_chunked(req),
                     head_only: req.method == http::Method.Head, ok: false };
    if ctx.conn_fd < 0 || !apply_cookies(ctx, res) { return s; }
    s.ok = http::begin_chunked(s.conn, res, s.head_only, http::wants_keep_alive(req), s.chunked);
    ctx.streamed = s.ok;
    return s;
}

// One chunk. A HEAD request sends nothing and still gets true.
fn write(s: Stream&, data: const u8[:]) -> bool {
    if !s.ok { return false; }
    if s.head_only { return true; }
    if http::send_chunk(s.conn, data, s.chunked) { return true; }
    s.ok = false;
    s.conn.shutdown_write();   // a half-written body must not be followed by another reply on a kept connection
    return false;
}

// Ends the body. Call it once; without it run_worker closes the connection, since the body was never terminated.
fn end(ctx: Ctx&, s: Stream&) -> bool {
    if !s.ok { return false; }
    s.ok = false;
    ctx.stream_ended = s.head_only || http::end_chunked(s.conn, s.chunked);
    return ctx.stream_ended;
}
