// Part of goose-web. Import with `import web.static;`.

namespace web;

import std;
import net;
import net.http;
import web;

// Answers 304 when If-None-Match carries the ETag of the representation to send; otherwise returns the index to send, so run_worker sends the embedded bytes.
// immutable is for the hashed URL, whose name changes with the bytes. gz is the index of a gzip variant, or -1: the plain ETag
// and the variant's differ, because a cache must not take one for the other.
fn send_static(req: const http::Request&, res: http::Response&, index: i64, gz: i64, content_type: const u8[:], etag: const u8[:], immutable: bool) -> i64 {
    var tag: u8[>..] = [];
    tag.append(etag);
    var sent = index;
    var coded = false;
    if gz >= 0 {
        http::set_header(res, "Vary", "Accept-Encoding");
        if http::accepts(req, "gzip") {
            coded = true;
            sent = gz;
            tag.pop();
            tag.append("-gz\"");
        }
    }
    http::set_header(res, "ETag", tag);
    http::set_header(res, "Cache-Control", if immutable { "public, max-age=31536000, immutable" } else { "public, max-age=0, must-revalidate" });
    let inm, has = http::header(req, "if-none-match");
    if has && find(inm, tag) >= 0 {
        res.status = http::Status.NotModified;
        return -1;
    }
    if coded { http::set_header(res, "Content-Encoding", "gzip"); }
    res.status = http::Status.Ok;
    res.content_type.clear();
    res.content_type.append(content_type);
    return sent;
}
