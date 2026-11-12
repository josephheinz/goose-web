// Part of goose-web. Import with `import web.push;`.
// These set ctx and res only; run_worker moves the socket to the hub after the handler returns.

namespace web;

import std;
import net;
import net.http;
import net.hub;
import web;

let BASE64_BYTES = byte_set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/");

fn hub_of(ctx: const Ctx&) -> net::Hub { net::Hub { handle: ctx.hub } }

fn no_hub(res: http::Response&) {
    http::json_error(res, http::Status.ServiceUnavailable, "no hub");
}

fn set_topic(ctx: Ctx&, topic: const u8[:]) {
    ctx.topic.clear();
    ctx.topic.append(topic);
}

// Server-sent events and other long-lived GETs: the caller sets res.content_type (text/event-stream for SSE) and
// run_worker sends the head, then the hub owns the connection. heartbeat goes out as a chunk every ping interval.
// False after writing a reply: 503 without a hub, 400 for HEAD, an HTTP/1.0 request or a topic or heartbeat over 64 bytes.
fn subscribe(req: const http::Request&, ctx: Ctx&, res: http::Response&, topic: const u8[:], heartbeat: const u8[:] = "") -> bool {
    if ctx.hub == 0 { no_hub(res); return false; }
    if req.method == http::Method.Head { http::json_error(res, http::Status.BadRequest, "cannot subscribe with HEAD"); return false; }
    if !http::supports_chunked(req) { http::json_error(res, http::Status.BadRequest, "subscribe needs HTTP/1.1"); return false; }
    if topic.len > 64 || heartbeat.len > 64 { http::json_error(res, http::Status.BadRequest, "topic or heartbeat too long"); return false; }
    http::set_header(res, "Cache-Control", "no-store");
    http::set_header(res, "X-Accel-Buffering", "no");   // nginx must not buffer the stream
    set_topic(ctx, topic);
    ctx.heartbeat.clear();
    ctx.heartbeat.append(heartbeat);
    ctx.detach = Detach.Stream;
    return true;
}

fn has_token(value: const u8[:], token: const u8[:]) -> bool {
    var start = 0;
    for i in value.len + 1 {
        if i == value.len || value[i] == ',' {
            if http::eq_nocase(trim(value[start..i]), token) { return true; }
            start = i + 1;
        }
    }
    return false;
}

// A 16-byte key is 22 base64 digits and "==", and the last digit has only its top 2 bits set.
fn key_valid(key: const u8[:]) -> bool {
    if key.len != 24 || key[22] != '=' || key[23] != '=' { return false; }
    for i in 22 { if !BASE64_BYTES.members[key[i]] { return false; } }
    let last = key[21];
    return last == 'A' || last == 'Q' || last == 'g' || last == 'w';
}

// The host[:port] of an Origin value; "" when it is not an http(s) origin.
fn origin_authority(origin: const u8[:]) -> const u8[:] {
    var rest = origin;
    if http::eq_nocase(origin[..min(origin.len, 7)], "http://") { rest = origin[7..]; }
    else if http::eq_nocase(origin[..min(origin.len, 8)], "https://") { rest = origin[8..]; }
    else { return ""; }
    for c, i in rest { if c == '/' { return rest[..i]; } }
    return rest;
}

// Completes the handshake: 101 here, and run_worker hands the socket to the hub. allow_origin ("host[:port]" or a
// full origin) admits one more site than the page's own host; a browser sends Origin on every WebSocket, so this is
// what stops another site from using a visitor's cookies. Non-browser clients send no Origin and pass.
// False after writing a reply: 503 without a hub, 426 (Sec-WebSocket-Version: 13) for a request that is not a version-13
// upgrade, 400 for a malformed handshake, 403 for another origin.
fn websocket(req: const http::Request&, ctx: Ctx&, res: http::Response&, topic: const u8[:], allow_origin: const u8[:] = "") -> bool {
    if ctx.hub == 0 { no_hub(res); return false; }
    if topic.len > 64 { http::json_error(res, http::Status.BadRequest, "topic too long"); return false; }
    let upgrade, has_upgrade = http::header(req, "Upgrade");
    let version, has_version = http::header(req, "Sec-WebSocket-Version");
    if !has_upgrade || !http::eq_nocase(trim(upgrade), "websocket") || !has_version || trim(version) != "13" {
        http::json_error(res, http::Status.Other { code: 426 }, "WebSocket version 13 required");
        http::set_header(res, "Sec-WebSocket-Version", "13");
        return false;
    }
    let connection, has_connection = http::header(req, "Connection");
    let key, has_key = http::header(req, "Sec-WebSocket-Key");
    if req.method != http::Method.Get || !has_connection || !has_token(connection, "upgrade") || !has_key || !key_valid(trim(key)) {
        http::json_error(res, http::Status.BadRequest, "bad WebSocket handshake");
        return false;
    }
    let origin, has_origin = http::header(req, "Origin");
    if has_origin {
        let host, has_host = http::header(req, "Host");
        let from = origin_authority(trim(origin));
        let own = has_host && from.len > 0 && http::eq_nocase(from, trim(host));
        let allowed = allow_origin.len > 0 && (http::eq_nocase(from, allow_origin) || http::eq_nocase(trim(origin), allow_origin));
        if !own && !allowed {
            http::json_error(res, http::Status.Forbidden, "cross-origin WebSocket refused");
            return false;
        }
    }
    res.body.clear();
    res.status = http::Status.SwitchingProtocols;
    http::set_header(res, "Upgrade", "websocket");
    http::add_header(res, "Sec-WebSocket-Accept", http::websocket_accept(trim(key)));
    set_topic(ctx, topic);
    ctx.detach = Detach.WebSocket;
    return true;
}

// To every connection on topic. False when there is no hub or the hub's queue is full.
fn publish(ctx: const Ctx&, topic: const u8[:], data: const u8[:], binary: bool = false) -> bool {
    if ctx.hub == 0 { return false; }
    return net::publish(hub_of(ctx), topic, data, binary);
}

// To one connection, by the id socket::open and socket::message receive.
fn send(ctx: const Ctx&, id: u64, data: const u8[:], binary: bool = false) -> bool {
    if ctx.hub == 0 { return false; }
    return net::send(hub_of(ctx), id, data, binary);
}

fn close_socket(ctx: const Ctx&, id: u64) {
    if ctx.hub != 0 { net::close(hub_of(ctx), id); }
}

// 0 without a hub; "" counts every connection.
fn subscribers(ctx: const Ctx&, topic: const u8[:]) -> i64 {
    if ctx.hub == 0 { return 0; }
    return net::count(hub_of(ctx), topic);
}
