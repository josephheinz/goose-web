// Multipart uploads (DESIGN-ADDENDUM-14, step 3), without sockets. The C helpers have their own test (test/upload_c.sh).
//   goose build test/upload_test.goose && test/upload_test
// Every fixture is parsed twice: from memory (req.body) and from a spool file (ctx.spool, the head only in the request).
import gweb from "..";
import gweb.forms.upload;
import gweb.forms.valid;
import net from "../../goose-net";
import net.http;
import std;

var failures = 0;
var checks = 0;
var spool_n = 0;

const DIR = ".gweb.upload-test";
const B = "----gwTestBoundary7MA4YWxk";

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

// ---------------------------------------------------------------- fixtures

fn add_text(out: u8[>..]&, b: const u8[:], name: const u8[:], value: const u8[:]) {
    format(out, "--", b, "\r\nContent-Disposition: form-data; name=\"", name, "\"\r\n\r\n", value, "\r\n");
}

fn add_file(out: u8[>..]&, b: const u8[:], name: const u8[:], filename: const u8[:], ctype: const u8[:], data: const u8[:]) {
    format(out, "--", b, "\r\nContent-Disposition: form-data; name=\"", name, "\"; filename=\"", filename, "\"\r\nContent-Type: ", ctype, "\r\n\r\n");
    out.append(data);
    out.append("\r\n");
}

fn end_body(out: u8[>..]&, b: const u8[:]) { format(out, "--", b, "--\r\n"); }

fn pattern(out: u8[>..]&, n: i64) {
    out.clear();
    for i in n { out.push((i * 31 + 7) as u8); }
}

fn content_type(out: u8[>..]&, b: const u8[:]) {
    out.clear();
    format(out, "multipart/form-data; boundary=", b);
}

// ---------------------------------------------------------------- running a parse

fn new_ctx() -> gweb::Ctx {
    var ctx = gweb::new_ctx(0, -1);
    ctx.upload_dir.append(DIR);
    return ctx;
}

// Deletes the spool file and the unsaved uploads, as run_worker does after the reply.
fn cleanup(ctx: gweb::Ctx&) {
    if ctx.spool.len > 0 { gweb::c_up_unlink(ctx.spool); }
    for i in ctx.uploads.len { gweb::c_up_unlink(ctx.uploads[i].path); }
}

// Parses body under the content type ct, from memory or from a spool file. out gets the urlencoded body.
fn parse(ctx: gweb::Ctx&, res: http::Response&, ct: const u8[:], body: const u8[:], disk: bool, out: u8[>..]&) -> bool {
    var raw: u8[>..] = [];
    format(raw, "POST /f HTTP/1.1\r\nHost: a\r\nContent-Type: ", ct, "\r\nContent-Length: ", body.len, "\r\n\r\n");
    if disk {
        spool_n += 1;
        var path: u8[..128] = "";
        format(path, DIR, "/gw-test-spool-", spool_n);
        let fd = gweb::c_up_create(path);
        check(fd >= 0, "spool file created");
        gweb::c_up_write(fd, body);
        gweb::c_up_close(fd);
        ctx.spool.append(path);
    } else {
        raw.append(body);
    }
    let req, parsed = http::parse_request(raw);
    return gweb::multipart_begin(req, ctx, res, out);
}

fn file_bytes(path: const u8[:], out: u8[>..]&) -> bool {
    out.clear();
    return read_file(path, out);
}

fn expect_fail(ct: const u8[:], body: const u8[:], status: http::Status, what: const u8[:]) {
    for d in 2 {
        var ctx = new_ctx();
        var res = http::new_response();
        var out: u8[>..] = [];
        check(!parse(ctx, res, ct, body, d == 1, out), what);
        check(res.status == status, what);
        check(out.len == 0, what);
        cleanup(ctx);
    }
}

fn main() {
    gweb::c_up_mkdir(DIR);
    gweb::c_up_sweep(DIR);

    var ct: u8[>..] = [];
    content_type(ct, B);

    // is_multipart and content_length
    var rawm: u8[>..] = [];
    format(rawm, "POST /f HTTP/1.1\r\nHost: a\r\nContent-Type: ", ct, "\r\nContent-Length: 12\r\n\r\n");
    let rm, pm = http::parse_request(rawm);
    check(gweb::is_multipart(rm), "multipart detected");
    check_num(gweb::content_length(rm), 12, "content_length");
    let ru, pu = http::parse_request("POST /f HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: x\r\n\r\n");
    check(!gweb::is_multipart(ru), "urlencoded is not multipart");
    check_num(gweb::content_length(ru), -1, "malformed content_length");
    let rn, pn = http::parse_request("POST /f HTTP/1.1\r\nHost: a\r\n\r\n");
    check(!gweb::is_multipart(rn), "no content type");
    check_num(gweb::content_length(rn), 0, "absent content_length");
    let ri, pi = http::parse_request("POST /f HTTP/1.1\r\nContent-Type: Multipart/Form-Data;boundary=x\r\n\r\n");
    check(gweb::is_multipart(ri), "case-insensitive type");
    let rx, px = http::parse_request("POST /f HTTP/1.1\r\nContent-Type: multipart/form-datax\r\n\r\n");
    check(!gweb::is_multipart(rx), "longer type name");

    // The main fixture: text fields (percent-encoded in the result, in order), two files, an untouched file input.
    var png: u8[>..] = [];
    png.append("\x89PNG\r\n\x1A\n");
    png.append("data\r\nwith CRLF\r\n\r\n--not-the-boundary\r\n and ----gwTestBoundary7MA4YW (almost)");
    var fixture: u8[>..] = [];
    add_text(fixture, B, "_csrf", "tok123");
    add_text(fixture, B, "title", "Hello World & \xC3\xA9");
    add_file(fixture, B, "avatar", "me.png", "image/png", png);
    add_text(fixture, B, "note", "line1\r\nline2");
    add_file(fixture, B, "empty", "", "application/octet-stream", "");
    add_file(fixture, B, "doc", "r\xC3\xA9sum\xC3\xA9 v2.pdf", "application/pdf", "%PDF-1.4 body");
    add_text(fixture, B, "blank", "");
    end_body(fixture, B);
    for d in 2 {
        let how = if d == 1 { "disk" } else { "memory" };
        var ctx = new_ctx();
        var res = http::new_response();
        var out: u8[>..] = [];
        check(parse(ctx, res, ct, fixture, d == 1, out), how);
        check_eq(out, "_csrf=tok123&title=Hello%20World%20%26%20%C3%A9&note=line1%0D%0Aline2&blank=", "urlencoded body, in order");
        check_num(ctx.uploads.len, 2, "two files recorded (empty input dropped)");
        check_eq(ctx.uploads[0].field, "avatar", "field");
        check_eq(ctx.uploads[0].filename, "me.png", "filename");
        check_eq(ctx.uploads[0].content_type, "image/png", "content_type");
        check_num(ctx.uploads[0].size, png.len, "size");
        var got: u8[>..] = [];
        check(file_bytes(ctx.uploads[0].path, got), "file readable");
        check(got == png, "bytes equal, CRLF and boundary lookalikes intact");
        check(starts_with(ctx.uploads[0].path, DIR), "file in the upload dir");
        check_eq(ctx.uploads[1].field, "doc", "second field");
        check_eq(ctx.uploads[1].filename, "r\xC3\xA9sum\xC3\xA9 v2.pdf", "filename keeps unicode");
        check_num(ctx.uploads[1].size, 13, "second size");
        check(file_bytes(ctx.uploads[1].path, got) && got == "%PDF-1.4 body", "second bytes");

        // form_upload looks in ctx.uploads only
        var errs = gweb::no_errors();
        var up = gweb::Upload { field: "", filename: "", content_type: "", size: 0, path: "" };
        check(gweb::form_upload(ctx, "avatar", up, errs, true), "form_upload finds it");
        check_eq(up.filename, "me.png", "form_upload copies");
        check(!gweb::form_upload(ctx, "empty", up, errs, true), "empty input is missing");
        check_eq(gweb::error_for(errs, "empty"), "Required.", "required error");
        check(gweb::form_upload(ctx, "nothing", up, errs, false), "optional missing is fine");
        check(!gweb::has_error(errs, "nothing"), "no error for optional");
        check(!gweb::form_upload(ctx, "title", up, errs, true), "a text field is not an upload");
        check(!gweb::form_upload(ctx, "_csrf", up, errs, true), "csrf is not an upload");

        // sniff and check_upload on a real file
        check_eq(gweb::sniff(ctx.uploads[0]), "image/png", "sniff the saved png");
        check_eq(gweb::sniff(ctx.uploads[1]), "application/pdf", "sniff the saved pdf");
        var errs2 = gweb::no_errors();
        check(gweb::check_upload(errs2, "avatar", ctx.uploads[0], 1000, ["image/png", "image/jpeg"]), "png allowed");
        check(!gweb::check_upload(errs2, "doc", ctx.uploads[1], 1000, ["image/png", "image/jpeg"]), "pdf refused");
        check_eq(gweb::error_for(errs2, "doc"), "This file type is not allowed.", "type message");
        check(!gweb::check_upload(errs2, "avatar2", ctx.uploads[0], 10, ["image/png"]), "too large");
        check_eq(gweb::error_for(errs2, "avatar2"), "The file is too large.", "size message");
        check(!gweb::check_upload(errs2, "doc", ctx.uploads[0], 1000, ["image/png"]), "skipped when the field has an error");
        var none = gweb::Upload { field: "", filename: "", content_type: "", size: 0, path: "" };
        check(gweb::check_upload(errs2, "none", none, 10, ["image/png"]), "no file: nothing to check");

        // save_upload: moves, never overwrites
        var dest: u8[..128] = "";
        format(dest, DIR, "/saved-", d, ".png");
        gweb::c_up_unlink(dest);
        check(gweb::save_upload(ctx.uploads[0], dest), "save works");
        check(file_bytes(dest, got) && got == png, "saved bytes");
        check(gweb::c_up_open_read(ctx.uploads[0].path) < 0, "temp path gone after save");
        check(!gweb::save_upload(ctx.uploads[1], dest), "save refuses an existing dest");
        check(file_bytes(dest, got) && got == png, "existing dest untouched");
        check(file_bytes(ctx.uploads[1].path, got), "source kept after a refused save");
        let saved_path = ctx.uploads[1].path;
        var saved_copy: u8[..256] = "";
        saved_copy.append(saved_path);
        let spool_copy_len = ctx.spool.len;

        // cleanup removes what was not saved, the spool file too, and tolerates what was saved
        cleanup(ctx);
        check(gweb::c_up_open_read(saved_copy) < 0, "unsaved upload deleted");
        check(gweb::c_up_open_read(ctx.uploads[0].path) < 0, "saved one: nothing left at the temp path");
        check(file_bytes(dest, got) && got == png, "cleanup leaves the saved file");
        if d == 1 { check(spool_copy_len > 0 && gweb::c_up_open_read(ctx.spool) < 0, "spool deleted"); }
        gweb::c_up_unlink(dest);
    }

    // Quoted and unquoted parameters, other header order, a header with odd spacing, lower-case names.
    var odd: u8[>..] = [];
    format(odd, "preamble ignored\r\n--", B, "\r\ncontent-type: text/plain\r\nCONTENT-DISPOSITION: form-data; filename=plain.txt; name=up\r\n\r\nraw\r\n");
    format(odd, "--", B, "\r\nContent-Disposition:form-data;name=t\r\n\r\nv;1=2\r\n");
    format(odd, "--", B, "\r\nContent-Disposition: form-data; name=\"a;b\"; filename=\"x;y=z.txt\"\r\n\r\nq\r\n");
    end_body(odd, B);
    format(odd, "epilogue ignored");
    for d in 2 {
        var ctx = new_ctx();
        var res = http::new_response();
        var out: u8[>..] = [];
        check(parse(ctx, res, ct, odd, d == 1, out), "odd headers parse");
        check_eq(out, "t=v%3B1%3D2", "unquoted name");
        check_num(ctx.uploads.len, 2, "two files");
        check_eq(ctx.uploads[0].field, "up", "unquoted name of a file");
        check_eq(ctx.uploads[0].filename, "plain.txt", "unquoted filename");
        check_eq(ctx.uploads[0].content_type, "text/plain", "part content type");
        check_eq(ctx.uploads[1].field, "a;b", "quoted name with ;");
        check_eq(ctx.uploads[1].filename, "x;y=z.txt", "quoted filename with ; and =");
        cleanup(ctx);
    }

    // A boundary given in quotes.
    var qct: u8[>..] = [];
    format(qct, "multipart/form-data; charset=utf-8; boundary=\"", B, "\"");
    for d in 2 {
        var ctx = new_ctx();
        var res = http::new_response();
        var out: u8[>..] = [];
        check(parse(ctx, res, qct, fixture, d == 1, out), "quoted boundary");
        check_num(ctx.uploads.len, 2, "quoted boundary: files");
        cleanup(ctx);
    }

    // A file part with a control byte and a long name: filename is cleaned and cut at 128.
    var longname: u8[>..] = [];
    for i in 200 { longname.push('a'); }
    var ctl: u8[>..] = [];
    add_file(ctl, B, "f", "x\x01y\x7Fz.txt", "text/plain", "1");
    add_file(ctl, B, "g", longname, "text/plain", "2");
    end_body(ctl, B);
    for d in 2 {
        var ctx = new_ctx();
        var res = http::new_response();
        var out: u8[>..] = [];
        check(parse(ctx, res, ct, ctl, d == 1, out), "control bytes parse");
        check_eq(ctx.uploads[0].filename, "xyz.txt", "control bytes removed");
        check_num(ctx.uploads[1].filename.len, 128, "filename cut at 128");
        cleanup(ctx);
    }

    // A boundary that straddles a 64 KiB window: sweep the file size so the delimiter crosses the edge at every offset.
    var swept = 0;
    for n in 65380..65720 {
        var data: u8[>..] = [];
        pattern(data, n);
        var body: u8[>..] = [];
        add_text(body, B, "a", "1");
        add_file(body, B, "big", "big.bin", "application/octet-stream", data);
        add_text(body, B, "z", "2");
        end_body(body, B);
        var ctx = new_ctx();
        var res = http::new_response();
        var out: u8[>..] = [];
        var ok = parse(ctx, res, ct, body, true, out);
        var got: u8[>..] = [];
        if !ok || ctx.uploads.len != 1 || out != "a=1&z=2" || !file_bytes(ctx.uploads[0].path, got) || got != data {
            check(false, "window straddle");
            print("  at size ", n);
        } else { swept += 1; }
        cleanup(ctx);
    }
    check_num(swept, 340, "all straddling sizes parse from disk");

    // A file far larger than a window, from disk and from memory.
    var huge: u8[>..] = [];
    pattern(huge, 300000);
    var hb: u8[>..] = [];
    add_file(hb, B, "huge", "h.bin", "application/octet-stream", huge);
    end_body(hb, B);
    for d in 2 {
        var ctx = new_ctx();
        var res = http::new_response();
        var out: u8[>..] = [];
        check(parse(ctx, res, ct, hb, d == 1, out), "300 KB file");
        var got: u8[>..] = [];
        check(file_bytes(ctx.uploads[0].path, got) && got == huge, "300 KB bytes");
        check_num(ctx.uploads[0].size, 300000, "300 KB size");
        cleanup(ctx);
    }

    // Limits: 64 parts, 8 files, 64 KiB text, 16 KiB headers.
    var parts64: u8[>..] = [];
    for i in 64 { add_text(parts64, B, "f", "x"); }
    end_body(parts64, B);
    for d in 2 {
        var ctx = new_ctx();
        var res = http::new_response();
        var out: u8[>..] = [];
        check(parse(ctx, res, ct, parts64, d == 1, out), "64 parts are fine");
        cleanup(ctx);
    }
    var parts65: u8[>..] = [];
    for i in 65 { add_text(parts65, B, "f", "x"); }
    end_body(parts65, B);
    expect_fail(ct, parts65, http::Status.PayloadTooLarge, "65th part is 413");

    var files8: u8[>..] = [];
    for i in 8 { add_file(files8, B, "f", "a.txt", "text/plain", "data"); }
    end_body(files8, B);
    for d in 2 {
        var ctx = new_ctx();
        var res = http::new_response();
        var out: u8[>..] = [];
        check(parse(ctx, res, ct, files8, d == 1, out), "8 files are fine");
        check_num(ctx.uploads.len, 8, "8 recorded");
        cleanup(ctx);
    }
    var files9: u8[>..] = [];
    for i in 9 { add_file(files9, B, "f", "a.txt", "text/plain", "data"); }
    end_body(files9, B);
    expect_fail(ct, files9, http::Status.PayloadTooLarge, "9th file is 413");

    var text_ok: u8[>..] = [];
    var text_big: u8[>..] = [];
    var filler: u8[>..] = [];
    for i in 65536 { filler.push('x'); }
    add_text(text_ok, B, "t", filler);
    end_body(text_ok, B);
    filler.push('x');
    add_text(text_big, B, "t", filler);
    end_body(text_big, B);
    for d in 2 {
        var ctx = new_ctx();
        var res = http::new_response();
        var out: u8[>..] = [];
        check(parse(ctx, res, ct, text_ok, d == 1, out), "64 KiB text field is fine");
        check_num(out.len, 2 + 65536, "text field in the body");
        cleanup(ctx);
    }
    expect_fail(ct, text_big, http::Status.PayloadTooLarge, "text field over 64 KiB is 413");

    var head_big: u8[>..] = [];
    var padv: u8[>..] = [];
    for i in 20000 { padv.push('p'); }
    format(head_big, "--", B, "\r\nContent-Disposition: form-data; name=\"a\"\r\nX-Pad: ", padv, "\r\n\r\nv\r\n");
    end_body(head_big, B);
    expect_fail(ct, head_big, http::Status.BadRequest, "part headers over 16 KiB are 400");
    var head_ok: u8[>..] = [];
    padv.clear();
    for i in 16000 { padv.push('p'); }
    format(head_ok, "--", B, "\r\nContent-Disposition: form-data; name=\"a\"\r\nX-Pad: ", padv, "\r\n\r\nv\r\n");
    end_body(head_ok, B);
    for d in 2 {
        var ctx = new_ctx();
        var res = http::new_response();
        var out: u8[>..] = [];
        check(parse(ctx, res, ct, head_ok, d == 1, out), "16000 bytes of headers are fine");
        cleanup(ctx);
    }

    // Malformed bodies are 400 and leave no body and no files behind.
    var bad: u8[>..] = [];
    format(bad, "--", B, "\r\nContent-Disposition: form-data\r\n\r\nv\r\n");
    end_body(bad, B);
    expect_fail(ct, bad, http::Status.BadRequest, "no name");

    bad.clear();
    format(bad, "--", B, "\r\nContent-Disposition: form-data; name=\"\"\r\n\r\nv\r\n");
    end_body(bad, B);
    expect_fail(ct, bad, http::Status.BadRequest, "empty name");

    bad.clear();
    format(bad, "--", B, "\r\nContent-Type: text/plain\r\n\r\nv\r\n");
    end_body(bad, B);
    expect_fail(ct, bad, http::Status.BadRequest, "no Content-Disposition");

    bad.clear();
    format(bad, "--", B, "\r\nContent-Disposition: attachment; name=\"a\"\r\n\r\nv\r\n");
    end_body(bad, B);
    expect_fail(ct, bad, http::Status.BadRequest, "not form-data");

    bad.clear();
    format(bad, "--", B, "\r\nthis is not a header\r\n\r\nv\r\n");
    end_body(bad, B);
    expect_fail(ct, bad, http::Status.BadRequest, "bad header line");

    bad.clear();
    format(bad, "--", B, "\r\n\r\nv\r\n");
    end_body(bad, B);
    expect_fail(ct, bad, http::Status.BadRequest, "part without headers");

    bad.clear();
    add_text(bad, B, "a", "1");
    format(bad, "--", B, "\r\nContent-Disposition: form-data; name=\"f\"; filename=\"f.txt\"\r\n\r\ntruncated, no closing boundary");
    expect_fail(ct, bad, http::Status.BadRequest, "no closing boundary, inside a file");

    bad.clear();
    add_text(bad, B, "a", "1");
    expect_fail(ct, bad, http::Status.BadRequest, "no final boundary after a part");

    bad.clear();
    format(bad, "--", B, "\r\nContent-Disposition: form-data; na");
    expect_fail(ct, bad, http::Status.BadRequest, "headers cut short");

    expect_fail(ct, "", http::Status.BadRequest, "empty body");
    expect_fail(ct, "just some text, no boundary at all", http::Status.BadRequest, "no boundary in the body");

    bad.clear();
    format(bad, "--", B, "X\r\n");
    expect_fail(ct, bad, http::Status.BadRequest, "junk after a boundary");

    expect_fail("multipart/form-data", fixture, http::Status.BadRequest, "no boundary parameter");
    expect_fail("multipart/form-data; boundary=", fixture, http::Status.BadRequest, "empty boundary");
    var longb: u8[>..] = [];
    for i in 71 { longb.push('b'); }
    var longct: u8[>..] = [];
    format(longct, "multipart/form-data; boundary=", longb);
    expect_fail(longct, fixture, http::Status.BadRequest, "boundary over 70 bytes");
    expect_fail("multipart/form-data; boundary=other", fixture, http::Status.BadRequest, "boundary that is not in the body");

    // The body of a failed parse has no half-written file left in the dir: only what ctx.uploads lists, which cleanup removes.
    var ctxf = new_ctx();
    var resf = http::new_response();
    var outf: u8[>..] = [];
    var half: u8[>..] = [];
    format(half, "--", B, "\r\nContent-Disposition: form-data; name=\"f\"; filename=\"f.txt\"\r\n\r\nabc");
    check(!parse(ctxf, resf, ct, half, false, outf), "unfinished file part");
    check_num(ctxf.uploads.len, 0, "unfinished file is not listed");
    check_num(gweb::c_up_sweep(DIR), 0, "and no file is left in the dir");

    // safe_name
    var n1: u8[>..] = [];
    gweb::safe_name(n1, "../../etc/passwd");
    check_eq(n1, "passwd", "path traversal");
    var n2: u8[>..] = [];
    gweb::safe_name(n2, ".htaccess");
    check_eq(n2, "htaccess", "leading dot");
    var n2b: u8[>..] = [];
    gweb::safe_name(n2b, "...hidden.txt");
    check_eq(n2b, "hidden.txt", "leading dots");
    var n3: u8[>..] = [];
    gweb::safe_name(n3, "r\xC3\xA9sum\xC3\xA9 (1).pdf");
    check_eq(n3, "r__sum____1_.pdf", "unicode and spaces become _") ;
    var n4: u8[>..] = [];
    var big: u8[>..] = [];
    for i in 300 { big.push('a'); }
    gweb::safe_name(n4, big);
    check_num(n4.len, 100, "300 bytes cut at 100");
    var n5: u8[>..] = [];
    gweb::safe_name(n5, "C:\\Users\\me\\pic.PNG");
    check_eq(n5, "pic.PNG", "windows path");
    var n6: u8[>..] = [];
    gweb::safe_name(n6, "");
    check_eq(n6, "file", "empty");
    var n7: u8[>..] = [];
    gweb::safe_name(n7, "dir/");
    check_eq(n7, "file", "trailing slash");
    var n8: u8[>..] = [];
    gweb::safe_name(n8, "a b;c.txt");
    check_eq(n8, "a_b_c.txt", "unsafe bytes");

    // sniff
    check_eq(gweb::sniff_bytes("\x89PNG\r\n\x1A\nrest"), "image/png", "png");
    check_eq(gweb::sniff_bytes("\xFF\xD8\xFF\xE0jfif"), "image/jpeg", "jpeg");
    check_eq(gweb::sniff_bytes("GIF89a..."), "image/gif", "gif89a");
    check_eq(gweb::sniff_bytes("GIF87a..."), "image/gif", "gif87a");
    check_eq(gweb::sniff_bytes("RIFF\x10\x00\x00\x00WEBPVP8 "), "image/webp", "webp");
    check_eq(gweb::sniff_bytes("RIFF\x10\x00\x00\x00WAVEfmt "), "", "riff but not webp");
    check_eq(gweb::sniff_bytes("%PDF-1.7"), "application/pdf", "pdf");
    check_eq(gweb::sniff_bytes("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>"), "", "svg is not an image");
    check_eq(gweb::sniff_bytes("<?xml version=\"1.0\"?><svg/>"), "", "xml svg");
    check_eq(gweb::sniff_bytes("<html>"), "", "html");
    check_eq(gweb::sniff_bytes(""), "", "empty");
    check_eq(gweb::sniff_bytes("\x89PN"), "", "short png");
    // sniff on files: the client's claim does not matter
    var sctx = new_ctx();
    var sres = http::new_response();
    var sout: u8[>..] = [];
    var sbody: u8[>..] = [];
    add_file(sbody, B, "liar", "evil.png", "image/png", "<svg onload=alert(1)></svg>");
    add_file(sbody, B, "jpg", "x.bin", "application/octet-stream", "\xFF\xD8\xFF\xE0xxxx");
    add_file(sbody, B, "gif", "x.gif", "image/gif", "GIF89a\x01\x00");
    add_file(sbody, B, "webp", "x.webp", "image/webp", "RIFF\x04\x00\x00\x00WEBP");
    end_body(sbody, B);
    check(parse(sctx, sres, ct, sbody, false, sout), "sniff fixture");
    check_eq(gweb::sniff(sctx.uploads[0]), "", "a file claiming image/png that is svg");
    check_eq(gweb::sniff(sctx.uploads[1]), "image/jpeg", "jpeg by bytes, whatever the claim");
    check_eq(gweb::sniff(sctx.uploads[2]), "image/gif", "gif file");
    check_eq(gweb::sniff(sctx.uploads[3]), "image/webp", "webp file");
    var serrs = gweb::no_errors();
    check(!gweb::check_upload(serrs, "liar", sctx.uploads[0], 1000, ["image/png"]), "svg refused though it claims png");
    cleanup(sctx);
    var gone = gweb::Upload { field: "x", filename: "", content_type: "", size: 5, path: "" };
    check_eq(gweb::sniff(gone), "", "no path");
    check(!gweb::save_upload(gone, DIR), "save without a file");

    // Urlencoded posts cannot point form_upload at a server file: only ctx.uploads is read.
    var ectx = new_ctx();
    var eerrs = gweb::no_errors();
    var eup = gweb::Upload { field: "", filename: "", content_type: "", size: 0, path: "" };
    check(!gweb::form_upload(ectx, "avatar", eup, eerrs, true), "nothing uploaded");

    gweb::c_up_sweep(DIR);
    print(checks - failures, " of ", checks, " checks pass");
    if failures > 0 { exit(1); }
}
