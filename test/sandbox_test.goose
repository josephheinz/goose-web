// FileOptions.sandbox (1.1): Content-Security-Policy: sandbox for any type, without sockets.
//   goose build test/sandbox_test.goose && test/sandbox_test
import gweb from "..";
import gweb.http.files;
import net from "../../goose-net";
import net.http;
import os;
import std;

var failures = 0;
var checks = 0;

const DIR = ".gweb.sandbox-test";

fn check(ok: bool, what: const u8[:]) {
    checks += 1;
    if !ok { failures += 1; print("FAIL ", what); }
}

fn has_csp(res: const http::Response&) -> bool { return find(res.headers, "Content-Security-Policy: sandbox\r\n") >= 0; }

fn sandboxed(extra: const u8[:], rel: const u8[:], opts: const gweb::FileOptions&) -> bool {
    let r = fetch(extra, rel, opts);
    return has_csp(r);
}

fn fetch(extra: const u8[:], rel: const u8[:], opts: const gweb::FileOptions&) -> http::Response {
    var raw: u8[>..] = [];
    format(raw, "GET /f HTTP/1.1\r\nHost: a\r\n", extra, "\r\n");
    let req, parsed = http::parse_request(raw);
    var ctx = gweb::_new_ctx(0, -1);
    var res = http::new_response();
    gweb::send_file(req, ctx, res, DIR, rel, opts);
    return res;
}

fn main() {
    make_dir(DIR);
    write_file(".gweb.sandbox-test/doc.pdf", "%PDF-1.4 x");
    write_file(".gweb.sandbox-test/a.html", "<p>x</p>");
    write_file(".gweb.sandbox-test/b.svg", "<svg/>");
    write_file(".gweb.sandbox-test/c.txt", "text");
    let plain = gweb::FileOptions { .. };
    var boxed = gweb::FileOptions { .. };
    boxed.sandbox = true;

    check(!sandboxed("", "doc.pdf", plain), "a PDF is not sandboxed by default");
    check(!sandboxed("", "c.txt", plain), "nor text");
    check(sandboxed("", "a.html", plain), "HTML always is");
    check(sandboxed("", "b.svg", plain), "SVG always is");
    let r = fetch("", "doc.pdf", boxed);
    check(r.status == http::Status.Ok && has_csp(r) && r.body == "%PDF-1.4 x", "sandbox: true sandboxes a PDF and still sends it");
    check(sandboxed("", "c.txt", boxed), "and text");
    var typed = gweb::FileOptions { .. };
    typed.sandbox = true;
    typed.content_type.append("application/octet-stream");
    check(sandboxed("", "c.txt", typed), "and a type set by opts.content_type");
    // A 304 keeps it, so a cache revalidation does not drop the header.
    let first = fetch("", "doc.pdf", boxed);
    let at = find(first.headers, "ETag: ");
    let etag_rest = first.headers[at + 6..];
    let etag = etag_rest[..find(etag_rest, "\r\n")];
    var inm: u8[>..] = [];
    format(inm, "If-None-Match: ", etag, "\r\n");
    let r304 = fetch(inm, "doc.pdf", boxed);
    check(r304.status == http::Status.NotModified && has_csp(r304), "a 304 carries it");
    // The whole-file and streamed paths share the header: a window of 4 bytes, no connection in this test, so the
    // streamed path is covered by test/cmsready.sh; here stream_over is only set to prove it changes nothing.
    var small = gweb::FileOptions { .. };
    small.sandbox = true;
    small.stream_over = 4;
    check(sandboxed("", "doc.pdf", small), "with stream_over below the size");

    delete_file(".gweb.sandbox-test/doc.pdf");
    delete_file(".gweb.sandbox-test/a.html");
    delete_file(".gweb.sandbox-test/b.svg");
    delete_file(".gweb.sandbox-test/c.txt");
    delete_dir(DIR);
    print(checks - failures, " of ", checks, " checks pass");
    if failures > 0 { exit(1); }
}
