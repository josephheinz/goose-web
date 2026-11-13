// Part of gweb. Import with `import gweb.auth.rate;`.
// Rate limiting and the client address (DESIGN-ADDENDUM-13, D6).

namespace gweb;

import std;
import net;
import net.http;
import gweb;

extern fn c_rate_take(key: const u8[:], now_ms: i64, period_ms: i64, limit: i64) -> i64 = "gweb_rate_take";
extern fn c_rate_reset() = "gweb_rate_reset";
extern fn c_now_ms() -> i64 = "gweb_now_ms";

// Appends addr without its port: "1.2.3.4:5" gives "1.2.3.4", "[::1]:5" gives "::1". Anything else is kept.
fn strip_port(addr: const u8[:], out: u8[>..]&) {
    if addr.len > 0 && addr[0] == '[' {
        for c, i in addr {
            if c == ']' { out.append(addr[1..i]); return; }
        }
        return;
    }
    var colons = 0;
    var last = 0;
    for c, i in addr {
        if c == ':' { colons += 1; last = i; }
    }
    // Several colons without brackets is a bare IPv6 address, which has no port to remove.
    if colons == 1 { out.append(addr[..last]); } else { out.append(addr); }
}

// Appends the client address to out, or nothing when unknown. Behind a proxy (auth.trust_proxy) it is the last
// X-Forwarded-For item, the one the nearest proxy appended; otherwise the peer of the connection.
fn client_ip(req: const http::Request&, ctx: const Ctx&, out: u8[>..]&) {
    if ctx.auth.trust_proxy {
        let xff, has = http::header(req, "x-forwarded-for");
        if has {
            let parts = split_on(xff, ',');
            let item = trim(parts[parts.len - 1]);
            if item.len > 0 { out.append(item); return; }
        }
    }
    if ctx.conn_fd < 0 { return; }
    let peer = net::peer_address(net::Socket { fd: ctx.conn_fd });
    strip_port(peer, out);
}

// 0 = allowed, else the milliseconds to wait. The clock is a parameter so tests need none.
fn rate_take_at(key: const u8[:], now_ms: i64, period_ms: i64, limit: i64) -> i64 {
    return c_rate_take(key, now_ms, period_ms, limit);
}

// Writes 429 with Retry-After in whole seconds, rounded up.
fn rate_refuse(res: http::Response&, wait_ms: i64) {
    var secs = (wait_ms + 999) / 1000;
    if secs < 1 { secs = 1; }
    var body: u8[>..] = [];
    format(body, "too many requests; try again in ", secs, " seconds\n");
    http::text(res, http::Status.Other { code: 429 }, body);
    var n: u8[>..] = [];
    format(n, secs);
    http::set_header(res, "Retry-After", n);
}

fn rate_check(res: http::Response&, key: const u8[:], limit: i64, period_s: i64) -> bool {
    let wait = rate_take_at(key, c_now_ms(), period_s * 1000, limit);
    if wait == 0 { return true; }
    rate_refuse(res, wait);
    return false;
}

// False after writing the 429 reply; the key is name, a NUL and the client address.
fn rate_limit(req: const http::Request&, ctx: Ctx&, res: http::Response&, name: const u8[:], limit: i64, period_s: i64) -> bool {
    var key: u8[>..] = [];
    key.append(name);
    key.push(0);
    client_ip(req, ctx, key);
    return rate_check(res, key, limit, period_s);
}

// Like rate_limit, for a caller-chosen key such as a username.
fn rate_limit_key(ctx: Ctx&, res: http::Response&, name: const u8[:], key: const u8[:], limit: i64, period_s: i64) -> bool {
    var k: u8[>..] = [];
    k.append(name);
    k.push(0);
    k.append(key);
    return rate_check(res, k, limit, period_s);
}
