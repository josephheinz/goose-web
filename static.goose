// Part of goose-web. Import with `import web.static;`.

namespace web;

import std;
import net;
import net.http;
import web;

// Answers 304 when If-None-Match carries etag; otherwise returns index, so run_worker sends the embedded bytes.
// immutable is for the hashed URL, whose name changes with the bytes. gz is the index of a gzip variant, or -1.
fn send_static(req: const http::Request&, res: http::Response&, index: i64, gz: i64, content_type: const u8[:], etag: const u8[:], immutable: bool) -> i64 {
    http::set_header(res, "ETag", etag);
    http::set_header(res, "Cache-Control", if immutable { "public, max-age=31536000, immutable" } else { "public, max-age=0, must-revalidate" });
    let inm, has = http::header(req, "if-none-match");
    if has && find(inm, etag) >= 0 {
        res.status = http::Status.NotModified;
        return -1;
    }
    res.status = http::Status.Ok;
    res.content_type.clear();
    res.content_type.append(content_type);
    return index;
}
