// Part of goose-web. Import with `import web.csrf;`.

namespace web;

import std;
import net;
import net.http;
import web;
import .form;

const CSRF_LEN = 32;
let CSRF_HEX = "0123456789abcdef";

// "__Host-gw_csrf" behind an HTTPS proxy (X-Forwarded-Proto), else "gw_csrf".
fn csrf_cookie_name(req: const http::Request&) -> const u8[:] {
    let proto, has = http::header(req, "x-forwarded-proto");
    return if has && trim(proto) == "https" { "__Host-gw_csrf" } else { "gw_csrf" };
}

// Exactly 32 lowercase hex digits.
fn csrf_valid(t: const u8[:]) -> bool {
    if t.len != CSRF_LEN { return false; }
    for c in t { if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) { return false; } }
    return true;
}

// Reuses the request's token or makes one; false after writing a 500.
fn csrf_begin(req: const http::Request&, ctx: Ctx&, res: http::Response&) -> bool {
    no_store(res);
    if ctx.csrf.len > 0 { return true; }
    let name = csrf_cookie_name(req);
    let sent, has = http::cookie(req, name);
    if has && csrf_valid(sent) {
        ctx.csrf.append(sent);
        return true;
    }
    var raw: u8[..16] = [0; 16];
    if c_entropy(raw) != 0 {
        for b in raw {
            ctx.csrf.push(CSRF_HEX[(b >> 4) as i64]);
            ctx.csrf.push(CSRF_HEX[(b & 15) as i64]);
        }
        if set_cookie(ctx, name, ctx.csrf, CookieOptions { secure: starts_with(name, "__Host-"), .. }) { return true; }
    }
    ctx.csrf.clear();
    http::json_error(res, http::Status.InternalServerError, "csrf token unavailable");
    return false;
}

// Compares without an early exit, so timing does not tell how many bytes matched.
fn token_equal(a: const u8[:], b: const u8[:]) -> bool {
    if a.len != CSRF_LEN || b.len != CSRF_LEN { return false; }
    var diff = 0;
    for i in CSRF_LEN { diff |= a[i] ^ b[i]; }
    return diff == 0;
}

// True for GET, HEAD, OPTIONS and Other; for the rest, false after writing a 403.
// A present X-CSRF-Token header is the only token read; otherwise the _csrf field of the body.
fn csrf_ok(req: const http::Request&, res: http::Response&) -> bool {
    let m = req.method;
    if m == http::Method.Get || m == http::Method.Head || m == http::Method.Options || m == http::Method.Other { return true; }

    let site, has_site = http::header(req, "sec-fetch-site");
    if has_site && trim(site) != "same-origin" && trim(site) != "none" {
        http::text(res, http::Status.Forbidden, "cross-site request refused\n");
        return false;
    }

    let cookie, has_cookie = http::cookie(req, csrf_cookie_name(req));
    var sent: u8[>..] = [];
    let head, has_head = http::header(req, "x-csrf-token");
    if has_head { sent.append(trim(head)); } else { form(req, "_csrf", sent); }
    if has_cookie && csrf_valid(cookie) && token_equal(cookie, sent) { return true; }
    http::text(res, http::Status.Forbidden, "CSRF token missing or wrong; reload the page and try again\n");
    return false;
}
