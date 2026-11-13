// gweb::send_file (DESIGN-ADDENDUM-20), without sockets: types, ETag and 304, HEAD, options and hostile paths.
// The stream for big files and symlinks out of the root are in test/cmsready.sh (a real server, a real link).
//   goose build test/files_test.goose && test/files_test
import gweb from "..";
import gweb.http.files;
import net from "../../goose-net";
import net.http;
import os;
import std;

var failures = 0;
var checks = 0;

const DIR = ".gweb.files-test";

fn check(ok: bool, what: const u8[:]) {
    checks += 1;
    if !ok { failures += 1; print("FAIL ", what); }
}
fn check_eq(got: const u8[:], want: const u8[:], what: const u8[:]) {
    checks += 1;
    if got != want { failures += 1; print("FAIL ", what, ": got '", got, "' want '", want, "'"); }
}
fn check_num(got: i64, want: i64, what: const u8[:]) {
    checks += 1;
    if got != want { failures += 1; print("FAIL ", what, ": got ", got, " want ", want); }
}

fn header_value(res: const http::Response&, name: const u8[:]) -> u8[..300] {
    var v: u8[..300] = "";
    var needle: u8[>..] = [];
    format(needle, name, ": ");
    let at = find(res.headers, needle);
    if at < 0 { return v; }
    let rest = res.headers[at + needle.len..];
    let end = find(rest, "\r\n");
    v.append(if end < 0 { rest } else { rest[..end] });
    return v;
}

fn fetch(method: const u8[:], extra: const u8[:], rel: const u8[:], opts: const gweb::FileOptions&) -> http::Response, bool {
    var raw: u8[>..] = [];
    format(raw, method, " /f HTTP/1.1\r\nHost: a\r\n", extra, "\r\n");
    let req, parsed = http::parse_request(raw);
    var ctx = gweb::_new_ctx(0, -1);
    var res = http::new_response();
    let ok = gweb::send_file(req, ctx, res, DIR, rel, opts);
    return res, ok;
}

let PLAIN = gweb::FileOptions { .. };

fn main() {
    make_dir(DIR);
    make_dir(".gweb.files-test/sub");
    write_file(".gweb.files-test/hello.txt", "hello file");
    write_file(".gweb.files-test/sub/pic.PNG", "pngbytes");
    write_file(".gweb.files-test/.secret", "hidden");
    write_file(".gweb.files-test/noext", "x");
    var big: u8[>..] = [];
    for i in 5000 { big.push((i % 251) as u8); }
    write_file(".gweb.files-test/big.bin", big);

    // 200, type, length, ETag, Cache-Control.
    let r1, ok1 = fetch("GET", "", "hello.txt", PLAIN);
    check(ok1, "hello.txt: found");
    check(r1.status == http::Status.Ok, "hello.txt: 200");
    check_eq(r1.body, "hello file", "hello.txt: body");
    check_eq(r1.content_type, "text/plain; charset=utf-8", "hello.txt: type");
    let etag = header_value(r1, "ETag");
    check(etag.len > 2 && etag[0] == '"', "hello.txt: strong ETag");
    check_eq(header_value(r1, "Cache-Control"), "public, max-age=0, must-revalidate", "revalidate by default");

    // 304 on a matching ETag, a list, and *; not on another tag.
    var inm: u8[>..] = [];
    format(inm, "If-None-Match: ", etag, "\r\n");
    let r2, ok2 = fetch("GET", inm, "hello.txt", PLAIN);
    check(ok2 && r2.status == http::Status.NotModified && r2.body.len == 0, "If-None-Match: 304 with no body");
    check_eq(header_value(r2, "ETag"), etag, "304 keeps the ETag");
    inm.clear();
    format(inm, "If-None-Match: \"zzz\", ", etag, "\r\n");
    let r3, ok3 = fetch("GET", inm, "hello.txt", PLAIN);
    check(r3.status == http::Status.NotModified, "If-None-Match list: 304");
    let r4, ok4 = fetch("GET", "If-None-Match: \"other\"\r\n", "hello.txt", PLAIN);
    check(r4.status == http::Status.Ok && r4.body == "hello file", "another tag: 200");
    let r5, ok5 = fetch("GET", "If-None-Match: *\r\n", "hello.txt", PLAIN);
    check(r5.status == http::Status.NotModified, "If-None-Match *: 304");

    // HEAD: the head of a GET (the server drops the body; Content-Length comes from res.body).
    let rh, okh = fetch("HEAD", "", "hello.txt", PLAIN);
    check(okh && rh.status == http::Status.Ok && rh.body.len == 10, "HEAD: 200 with the length");
    check_eq(header_value(rh, "ETag"), etag, "HEAD: the same ETag");

    // Types by extension, any case; an unknown one.
    let rp, okp = fetch("GET", "", "sub/pic.PNG", PLAIN);
    check_eq(rp.content_type, "image/png", "PNG: image/png");
    let rn, okn = fetch("GET", "", "noext", PLAIN);
    check_eq(rn.content_type, "application/octet-stream", "no extension: octet-stream");
    var o = PLAIN;
    o.content_type.append("text/x-custom");
    let rc, okc = fetch("GET", "", "hello.txt", o);
    check_eq(rc.content_type, "text/x-custom", "opts.content_type wins");

    // Options.
    var imm = PLAIN;
    imm.immutable = true;
    let ri, oki = fetch("GET", "", "hello.txt", imm);
    check_eq(header_value(ri, "Cache-Control"), "public, max-age=31536000, immutable", "immutable");
    var dl = PLAIN;
    dl.download = true;
    let rd, okd = fetch("GET", "", "hello.txt", dl);
    check_eq(header_value(rd, "Content-Disposition"), "attachment; filename=\"hello.txt\"", "download: attachment with the file's name");
    var named = PLAIN;
    named.download = true;
    named.filename.append("résumé \"v2\".txt");
    let rm, okm = fetch("GET", "", "hello.txt", named);
    check_eq(header_value(rm, "Content-Disposition"), "attachment; filename=\"r__sum__ _v2_.txt\"; filename*=UTF-8''r%C3%A9sum%C3%A9%20%22v2%22.txt", "named download: ASCII fallback and filename*");
    var crlf = PLAIN;
    crlf.download = true;
    crlf.filename.append("a\r\nSet-Cookie: x=1.txt");
    let rcr, okcr = fetch("GET", "", "hello.txt", crlf);
    check(okcr && find(rcr.headers, "\r\nSet-Cookie") < 0, "a newline in the download name cannot start a header");
    check_eq(header_value(rcr, "Content-Disposition"), "attachment; filename=\"a__Set-Cookie: x=1.txt\"; filename*=UTF-8''aSet-Cookie%3A%20x%3D1.txt", "control bytes are dropped or replaced");
    var inl = PLAIN;
    inl.filename.append("x.txt");
    let rl, okl = fetch("GET", "", "hello.txt", inl);
    check_eq(header_value(rl, "Content-Disposition"), "inline; filename=\"x.txt\"", "inline name");
    check_eq(header_value(r1, "Content-Disposition"), "", "no Content-Disposition by default");

    // A big file under stream_over 100: with no socket it is still read whole (gweb test has no connection).
    var small = PLAIN;
    small.stream_over = 100;
    let rb, okb = fetch("GET", "", "big.bin", small);
    check(okb && rb.body.len == 5000 && rb.body[250] == 250 && rb.body[251] == 0, "a file over stream_over without a connection: whole body");

    // Missing and hostile paths: 404, false.
    let hostile = ["", "/", "/etc/passwd", "missing.txt", "sub", "sub/", "../hello.txt", "sub/../hello.txt", "..", ".", "./hello.txt", "sub/./pic.PNG",
                   "..\\hello.txt", "sub\\pic.PNG", ".secret", "sub//pic.PNG", "hello.txt/", "hello.txt/x", "hello\0.txt", "hello.txt\n", "%2e%2e/hello.txt",
                   "....//hello.txt", "../../../../etc/passwd", "sub/..%2fhello.txt"];
    for h in hostile {
        let rx, okx = fetch("GET", "", h, PLAIN);
        var what: u8[>..] = [];
        format(what, "hostile path '", h, "': 404 and false");
        check(!okx && rx.status == http::Status.NotFound, what);
    }
    var long: u8[>..] = [];
    for i in 1100 { long.push('a'); }
    let rg, okg = fetch("GET", "", long, PLAIN);
    check(!okg && rg.status == http::Status.NotFound, "a path over 1,024 bytes: 404");
    check(!gweb::file_path_ok("a/../b") && gweb::file_path_ok("a/b.txt") && gweb::file_path_ok("a b/c-d_e.f"), "file_path_ok");
    // A root that does not exist.
    let req, parsed = http::parse_request("GET /f HTTP/1.1\r\nHost: a\r\n\r\n");
    var ctx = gweb::_new_ctx(0, -1);
    var res = http::new_response();
    check(!gweb::send_file(req, ctx, res, ".gweb.files-test-nope", "hello.txt", PLAIN), "a missing root: false");

    delete_file(".gweb.files-test/hello.txt");
    delete_file(".gweb.files-test/sub/pic.PNG");
    delete_file(".gweb.files-test/.secret");
    delete_file(".gweb.files-test/noext");
    delete_file(".gweb.files-test/big.bin");
    delete_dir(".gweb.files-test/sub");
    delete_dir(DIR);

    if failures > 0 { print("files_test: ", failures, " of ", checks, " checks FAILED"); exit(1); }
    print("files_test: ", checks, " checks passed");
}
