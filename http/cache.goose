// Part of gweb. Import with `import gweb.http.cache;`.

namespace gweb;

import std;
import net;
import net.http;
import gweb;
import forms.form;

extern fn c_cache_get(key: const u8[:], out: u8[>..]&) -> i32 = "gweb_cache_get";
extern fn c_cache_put(key: const u8[:], val: const u8[:], ttl_ms: i64) -> i32 = "gweb_cache_put";

extern fn c_epoch_bump() = "gweb_epoch_bump";
extern fn c_epoch() -> i64 = "gweb_epoch";

let CACHE_MAX_BODY = 1048576;
let CACHE_MAX_KEY = 1280;
let CACHE_FOREVER_MS = 31536000000;   // "until the epoch changes": a year
let CACHE_CONTROL = "public, max-age=0, must-revalidate";

// The same FNV-1a 64 format as gweb's etag_of for static files.
fn cache_etag(data: const u8[:]) -> u8[..24] {
    var h: u64 = 14695981039346656037;
    for c in data { h = (h ^ c) * 1099511628211; }
    var t: u8[..24] = "\"";
    let hex = "0123456789abcdef";
    for k in 16 { t.push(hex[(h >> ((15 - k) * 4) as u64) & 15]); }
    t.push('"');
    return t;
}

// -1 for anything but digits.
fn cache_num(s: const u8[:]) -> i64 {
    if s.len == 0 || s.len > 9 { return -1; }
    var n = 0;
    for c in s {
        if c < '0' || c > '9' { return -1; }
        n = n * 10 + (c - '0');
    }
    return n;
}

// Only whole-page GET and HEAD replies are shared; a fragment reply and a POST are per request.
fn cacheable_request(req: const http::Request&) -> bool {
    if req.method != http::Method.Get && req.method != http::Method.Head { return false; }
    return fragment(req).len == 0;
}

fn not_modified(req: const http::Request&, etag: const u8[:]) -> bool {
    let inm, has = http::header(req, "if-none-match");
    return has && find(inm, etag) >= 0;
}

fn send_not_modified(res: http::Response&) {
    res.status = http::Status.NotModified;
    res.content_type.clear();
    res.body.clear();
}

// Clears every worker's page cache: call it after a content change (DESIGN-ADDENDUM-19, D7). Each worker drops its
// entries the next time it looks in its cache. Safe from any thread.
fn epoch_bump() { c_epoch_bump(); }
fn epoch() -> i64 { return c_epoch(); }

// An entry is "<content type length> <headers length> <etag length>\n", then those three, then the body.
// True when the reply is filled in from the cache, as a 304 when If-None-Match matches.
// The middleware before it has already added its headers, and the stored ones include them: a line already present is not added again.
fn cache_serve(req: const http::Request&, ctx: Ctx&, res: http::Response&) -> bool {
    if req.target.len > 1024 { return false; }
    return cache_serve_key(req, ctx, res, req.target);
}

// The same with your own key, at most 1,280 bytes: a site that serves several hosts uses host + "\n" + path.
fn cache_serve_key(req: const http::Request&, ctx: Ctx&, res: http::Response&, key: const u8[:]) -> bool {
    if !cacheable_request(req) || key.len > CACHE_MAX_KEY { return false; }
    var v: u8[>..] = [];
    if c_cache_get(key, v) == 0 { return false; }
    let nl = find(v, "\n");
    if nl < 0 { return false; }
    let line = v[..nl];
    let a = find(line, " ");
    if a < 0 { return false; }
    let b = a + 1 + find(line[a + 1..], " ");
    if b <= a { return false; }
    let ct_len = cache_num(line[..a]);
    let h_len = cache_num(line[a + 1..b]);
    let e_len = cache_num(line[b + 1..]);
    if ct_len < 0 || h_len < 0 || e_len < 0 || nl + 1 + ct_len + h_len + e_len > v.len { return false; }
    let ct = v[nl + 1..nl + 1 + ct_len];
    let hs = v[nl + 1 + ct_len..nl + 1 + ct_len + h_len];
    let etag = v[nl + 1 + ct_len + h_len..nl + 1 + ct_len + h_len + e_len];
    let body = v[nl + 1 + ct_len + h_len + e_len..];
    if h_len > res.headers.cap - res.headers.len { return false; }
    var at = 0;
    while at < hs.len {
        let end = at + find(hs[at..], "\n") + 1;
        if end <= at { break; }
        if find(res.headers, hs[at..end]) < 0 { res.headers.append(hs[at..end]); }
        at = end;
    }
    if not_modified(req, etag) { send_not_modified(res); return true; }
    res.status = http::Status.Ok;
    res.content_type.clear();
    res.content_type.append(ct);
    res.body.clear();
    res.body.append(body);
    return true;
}

// Called after a page's reply is rendered. A reply that is shared must be the same for every visitor: only a plain 200
// that sets no cookie and no redirect is kept. The reply gets its ETag either way it is stored.
fn cache_store(req: const http::Request&, ctx: Ctx&, res: http::Response&, seconds: i64) {
    if seconds <= 0 || req.target.len > 1024 { return; }
    cache_put(req, ctx, res, req.target, seconds * 1000);
}

// Stores under your own key. seconds 0 keeps the reply until gweb::epoch_bump(). Never stores a reply that has a
// CSRF token, since the next visitor would get it.
fn cache_store_key(req: const http::Request&, ctx: Ctx&, res: http::Response&, key: const u8[:], seconds: i64) {
    if seconds < 0 || key.len > CACHE_MAX_KEY || ctx.csrf.len > 0 { return; }
    cache_put(req, ctx, res, key, if seconds == 0 { CACHE_FOREVER_MS } else { seconds * 1000 });
}

fn cache_put(req: const http::Request&, ctx: Ctx&, res: http::Response&, key: const u8[:], ttl_ms: i64) {
    if !cacheable_request(req) { return; }
    if ctx.outcome != Outcome.Continue || res.status != http::Status.Ok { return; }
    if ctx.set_cookies.len > 0 || res.body.len > CACHE_MAX_BODY { return; }
    let etag = cache_etag(res.body);
    if res.headers.cap - res.headers.len < 128 { return; }
    http::set_header(res, "ETag", etag);
    if find(res.headers, "Cache-Control:") < 0 { http::set_header(res, "Cache-Control", CACHE_CONTROL); }
    var e: u8[>..] = [];
    format(e, res.content_type.len, " ", res.headers.len, " ", etag.len, "\n", res.content_type, res.headers, etag, res.body);
    c_cache_put(key, e, ttl_ms);
    if not_modified(req, etag) { send_not_modified(res); }
}
