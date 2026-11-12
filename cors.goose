// Part of goose-web. Import with `import web.cors;`.
// CORS for routes, called in `before` (DESIGN-ADDENDUM-13, D8).

namespace web;

import std;
import net;
import net.http;
import web;

struct CorsOptions { origins: u8[..1024] = "", methods: u8[..128] = "GET, POST, PUT, PATCH, DELETE",
                     headers: u8[..256] = "Content-Type, X-CSRF-Token", credentials: bool = false, max_age: i64 = 600 }

fn cors_origin_allowed(opts: const CorsOptions&, origin: const u8[:]) -> bool {
    if origin.len == 0 { return false; }
    for item in split_on(opts.origins, ',') {
        if trim(item) == origin { return true; }
    }
    return false;
}

fn cors_overflow(res: http::Response&) -> bool {
    res.headers.clear();
    http::json_error(res, http::Status.InternalServerError, "response headers too large");
    return false;
}

// True to continue. False when the reply is final: a preflight answer, a refusal, or the 500 for oversized headers.
// "*" in origins matches every origin, but never with credentials (browsers refuse that pair).
fn cors(req: const http::Request&, ctx: Ctx&, res: http::Response&, opts: CorsOptions) -> bool {
    let raw, has = http::header(req, "origin");
    if !has { return true; }
    let origin = trim(raw);
    let any = trim(opts.origins) == "*" && !opts.credentials;
    let allowed = any || (trim(opts.origins) != "*" && cors_origin_allowed(opts, origin));
    let safe = req.method == http::Method.Get || req.method == http::Method.Head || req.method == http::Method.Options;
    let rm, has_rm = http::header(req, "access-control-request-method");
    let preflight = req.method == http::Method.Options && has_rm;

    if !allowed {
        // A cross-site form POST needs no preflight, so a credentialed route must refuse it here.
        if preflight || (!safe && opts.credentials) {
            http::text(res, http::Status.Forbidden, "CORS origin not allowed\n");
            return false;
        }
        return true;
    }

    // The origin is request bytes, so it goes through the checking add_header.
    if any {
        if !http::add_header(res, "Access-Control-Allow-Origin", "*") { return cors_overflow(res); }
    } else if !http::add_header(res, "Access-Control-Allow-Origin", origin) { return cors_overflow(res); }
    if !http::add_header(res, "Vary", "Origin") { return cors_overflow(res); }
    if opts.credentials && !http::add_header(res, "Access-Control-Allow-Credentials", "true") { return cors_overflow(res); }
    if !preflight { return true; }

    res.status = http::Status.NoContent;
    var age: u8[>..] = [];
    format(age, opts.max_age);
    if !http::add_header(res, "Access-Control-Allow-Methods", opts.methods)
        || !http::add_header(res, "Access-Control-Allow-Headers", opts.headers)
        || !http::add_header(res, "Access-Control-Max-Age", age) { return cors_overflow(res); }
    return false;
}
