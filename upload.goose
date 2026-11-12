// Part of goose-web. Import with `import web.upload;`.
// Multipart bodies become a plain urlencoded form plus files on disk (DESIGN-ADDENDUM-14, D7).
// struct Upload lives in web.goose, beside Ctx, which holds it.

namespace web;

import std;
import net;
import net.http;
import web;
import .valid;

extern fn c_up_getpid() -> i64 = "gweb_up_getpid";
extern fn c_up_open_read(path: const u8[:]) -> i32 = "gweb_up_open_read";
extern fn c_up_pread(fd: i32, off: i64, n: i64, out: u8[>..]&) -> i64 = "gweb_up_pread";
extern fn c_up_create(path: const u8[:]) -> i32 = "gweb_up_create";
extern fn c_up_write(fd: i32, data: const u8[:]) -> i32 = "gweb_up_write";
extern fn c_up_close(fd: i32) = "gweb_up_close";
extern fn c_up_save(src: const u8[:], dest: const u8[:]) -> i32 = "gweb_up_save";

const UPLOAD_WINDOW = 65536;       // bytes read from the spool file at a time
const UPLOAD_MAX_PARTS = 64;
const UPLOAD_MAX_FILES = 8;
const UPLOAD_MAX_TEXT = 65536;     // one text field
const UPLOAD_MAX_HEAD = 16384;     // the headers of one part

// Names the temp files; each worker thread's files also carry its slot, so a shared count cannot collide.
var upload_seq = 0;

// ---------------------------------------------------------------- small helpers

// Appends s percent-encoded: every byte except the unreserved ones.
fn pct_append(out: u8[>..]&, s: const u8[:]) {
    for c in s {
        if COOKIE_PLAIN_BYTES.members[c] { out.push(c); }
        else { out.push('%'); out.push(HEX_UPPER[c >> 4]); out.push(HEX_UPPER[c & 15]); }
    }
}

// The value of a ;-separated parameter in a header value ("form-data; name=\"a\"; filename=b"), appended to out;
// false when absent. A quoted value runs to the next quote and may hold ; or =. No backslash escapes: browsers do not send them.
fn param_value(s: const u8[:], key: const u8[:], out: u8[>..]&) -> bool {
    var i = 0;
    while i < s.len {
        while i < s.len && (s[i] == ' ' || s[i] == ';' || s[i] == '\t') { i += 1; }
        let ks = i;
        while i < s.len && s[i] != '=' && s[i] != ';' { i += 1; }
        if i >= s.len || s[i] == ';' { continue; }
        let found = http::eq_nocase(trim(s[ks..i]), key);
        i += 1;
        if i < s.len && s[i] == '"' {
            i += 1;
            let vs = i;
            while i < s.len && s[i] != '"' { i += 1; }
            if found { out.append(s[vs..i]); }
            i += 1;
        } else {
            let vs = i;
            while i < s.len && s[i] != ';' { i += 1; }
            if found { out.append(trim(s[vs..i])); }
        }
        if found { return true; }
    }
    return false;
}

// Reads the part's headers (the bytes before the blank line, without it). False for a line without ':', a missing
// or repeated Content-Disposition, one that is not form-data, or no name. filename is only appended when sent.
fn parse_part_head(h: const u8[:], name: u8[>..]&, filename: u8[>..]&, ctype: u8[>..]&, is_file: bool&) -> bool {
    var seen_disp = false;
    var pos = 0;
    while pos < h.len {
        let e = find(h[pos..], "\r\n");
        var line = h[pos..];
        if e >= 0 { line = h[pos..pos + e]; pos += e + 2; } else { pos = h.len; }
        let key, value, has = split_once(line, ':');
        if !has { return false; }
        let k = trim(key);
        if http::eq_nocase(k, "content-disposition") {
            if seen_disp { return false; }
            seen_disp = true;
            let v = trim(value);
            if v.len < 9 || !http::eq_nocase(v[..9], "form-data") { return false; }
            if !param_value(v, "name", name) { return false; }
            is_file = param_value(v, "filename", filename);
        } else if http::eq_nocase(k, "content-type") {
            ctype.append(trim(value));
        }
    }
    return seen_disp && name.len > 0;
}

// ---------------------------------------------------------------- the part being read

struct Part {
    is_file: bool, name: u8[..256], filename: u8[..128], ctype: u8[..96],
    fd: i32, size: i64, path: u8[..256],   // a file part's temp file
    count: i64,                // parts begun
    text: u8[>..]              // a text field's value so far (last: resizable)
}

fn new_part() -> Part {
    Part { is_file: false, name: "", filename: "", ctype: "", fd: -1, size: 0, path: "", count: 0, text: [] }
}

// Closes and deletes the file of a part that failed.
fn part_abort(p: Part&) {
    if p.fd >= 0 { c_up_close(p.fd); p.fd = -1; c_up_unlink(p.path); }
}

// 0, or the status to answer: 400 for bad headers, 413 over a limit, 500 when the file cannot be created.
fn part_begin(p: Part&, ctx: Ctx&, head: const u8[:]) -> i64 {
    var name: u8[>..] = [];
    var fname: u8[>..] = [];
    var ctype: u8[>..] = [];
    var is_file = false;
    if !parse_part_head(head, name, fname, ctype, is_file) { return 400; }
    if name.len > p.name.cap || (is_file && name.len > 64) { return 400; }
    p.count += 1;
    if p.count > UPLOAD_MAX_PARTS { return 413; }
    p.is_file = is_file;
    p.name.clear();
    p.name.append(name);
    p.filename.clear();
    for c in fname {
        if p.filename.len >= p.filename.cap { break; }
        if c >= 32 && c != 127 { p.filename.push(c); }
    }
    p.ctype.clear();
    p.ctype.append(ctype[..min(ctype.len, p.ctype.cap)]);
    p.text.clear();
    p.size = 0;
    p.fd = -1;
    if !is_file { return 0; }
    if p.filename.len > 0 && ctx.uploads.len >= UPLOAD_MAX_FILES { return 413; }
    if ctx.upload_dir.len == 0 || ctx.upload_dir.len + 48 > p.path.cap { return 500; }
    for attempt in 4 {
        upload_seq += 1;
        p.path.clear();
        format(p.path, ctx.upload_dir, "/gw-", c_up_getpid(), "-", ctx.worker, "-", upload_seq);
        p.fd = c_up_create(p.path);
        if p.fd >= 0 { return 0; }
    }
    return 500;
}

fn part_data(p: Part&, data: const u8[:]) -> i64 {
    if data.len == 0 { return 0; }
    if p.is_file {
        if c_up_write(p.fd, data) == 0 { return 500; }
        p.size += data.len;
        return 0;
    }
    if p.text.len + data.len > UPLOAD_MAX_TEXT { return 413; }
    p.text.append(data);
    return 0;
}

// A text part joins body as name=value; a file part is recorded in ctx.uploads (an empty one with no filename, which is
// what a browser sends for an untouched file input, is dropped).
fn part_end(p: Part&, ctx: Ctx&, body: u8[>..]&) -> i64 {
    if !p.is_file {
        if body.len > 0 { body.push('&'); }
        pct_append(body, p.name);
        body.push('=');
        pct_append(body, p.text);
        return 0;
    }
    c_up_close(p.fd);
    p.fd = -1;
    if p.filename.len == 0 && p.size == 0 { c_up_unlink(p.path); return 0; }
    if ctx.uploads.len >= UPLOAD_MAX_FILES { c_up_unlink(p.path); return 413; }
    var u = Upload { field: "", filename: "", content_type: "", size: p.size, path: "" };
    u.field.append(p.name);
    u.filename.append(p.filename);
    u.content_type.append(p.ctype);
    u.path.append(p.path);
    ctx.uploads.push(u);
    return 0;
}

// ---------------------------------------------------------------- the parser

// The window reader: appends up to UPLOAD_WINDOW bytes of the body from off to out, from memory or from the spool file.
// Returns the count; 0 at the end; -1 when the file cannot be read.
fn read_window(fd: i32, mem: const u8[:], off: i64, out: u8[>..]&) -> i64 {
    if fd < 0 {
        if off >= mem.len { return 0; }
        let n = min(UPLOAD_WINDOW, mem.len - off);
        out.append(mem[off..off + n]);
        return n;
    }
    return c_up_pread(fd, off, UPLOAD_WINDOW, out);
}

const MP_PREAMBLE = 0;   // before the first boundary
const MP_AFTER = 1;      // just after a boundary: "--" ends the body, CRLF starts a part
const MP_HEAD = 2;       // reading a part's headers
const MP_BODY = 3;       // reading a part's data
const MP_DONE = 4;

// Reads a whole multipart body, from fd when it is >= 0 and from mem otherwise, through one window at a time.
// acc holds the bytes not yet used: between windows only the last boundary-length bytes of a part's data (or its
// headers so far), so a boundary that straddles two windows is found. Returns 0 or the status to answer.
fn parse_multipart(fd: i32, mem: const u8[:], boundary: const u8[:], ctx: Ctx&, body: u8[>..]&) -> i64 {
    var delim: u8[>..] = [];
    delim.append("\r\n--");
    delim.append(boundary);
    let keep = delim.len - 1;
    var acc: u8[>..] = [];
    acc.append("\r\n");          // so the first boundary matches the delimiter too
    var chunk: u8[>..] = [];
    var rest: u8[>..] = [];
    var part = new_part();
    var state = MP_PREAMBLE;
    var status = 0;
    var off = 0;
    loop {
        var pos = 0;
        var more = true;
        while more && status == 0 && state != MP_DONE {
            let avail = acc[pos..];
            if state == MP_PREAMBLE {
                let i = find(avail, delim);
                if i >= 0 { pos += i + delim.len; state = MP_AFTER; }
                else { if avail.len > keep { pos += avail.len - keep; } more = false; }
            } else if state == MP_AFTER {
                if avail.len < 2 { more = false; }
                else if avail[0] == '-' && avail[1] == '-' { state = MP_DONE; }
                else if avail[0] == '\r' && avail[1] == '\n' { pos += 2; state = MP_HEAD; }
                else { status = 400; }
            } else if state == MP_HEAD {
                let i = find(avail, "\r\n\r\n");
                if avail.len >= 2 && avail[0] == '\r' && avail[1] == '\n' { status = 400; }
                else if i < 0 { if avail.len > UPLOAD_MAX_HEAD + 4 { status = 400; } more = false; }
                else if i > UPLOAD_MAX_HEAD { status = 400; }
                else {
                    status = part_begin(part, ctx, avail[..i]);
                    pos += i + 4;
                    state = MP_BODY;
                }
            } else {
                let i = find(avail, delim);
                if i >= 0 {
                    status = part_data(part, avail[..i]);
                    if status == 0 { status = part_end(part, ctx, body); }
                    pos += i + delim.len;
                    state = MP_AFTER;
                } else {
                    if avail.len > keep { status = part_data(part, avail[..avail.len - keep]); pos += avail.len - keep; }
                    more = false;
                }
            }
        }
        if status != 0 || state == MP_DONE { break; }
        rest.clear();
        rest.append(acc[pos..]);
        acc.clear();
        acc.append(rest);
        chunk.clear();
        let n = read_window(fd, mem, off, chunk);
        if n < 0 { status = 500; break; }
        if n == 0 { status = 400; break; }      // the body ended before the closing boundary
        off += n;
        acc.append(chunk);
    }
    part_abort(part);
    return status;
}

// ---------------------------------------------------------------- the API

// Called once by main() before the workers start: makes the upload directory and deletes files an earlier run left
// (names gnet-* and gw-*). Prints nothing; run_worker reports an unusable directory.
fn prepare_uploads(cfg: Config) {
    if cfg.upload_dir.len > 0 && c_up_mkdir(cfg.upload_dir) != 0 { c_up_sweep(cfg.upload_dir); }
}

fn is_multipart(req: const http::Request&) -> bool {
    let ct, has = http::header(req, "content-type");
    if !has { return false; }
    let t = trim(ct);
    if t.len < 19 || !http::eq_nocase(t[..19], "multipart/form-data") { return false; }
    return t.len == 19 || t[19] == ';' || t[19] == ' ';
}

fn multipart_fail(res: http::Response&, status: i64) {
    res.body.clear();
    if status == 413 { http::json_error(res, http::Status.PayloadTooLarge, "multipart body over a limit"); }
    else if status == 500 { http::json_error(res, http::Status.InternalServerError, "upload failed"); }
    else { http::json_error(res, http::Status.BadRequest, "malformed multipart body"); }
}

// Parses the body (req.body, or the file ctx.spool when set). Text fields are appended to body, urlencoded, in order,
// so web::form and web::csrf_ok see them; file parts are written to ctx.upload_dir/gw-<pid>-<worker>-<n> and listed in
// ctx.uploads, which run_worker deletes after the reply. False after writing 400 (malformed), 413 (over a limit) or 500.
fn multipart_begin(req: const http::Request&, ctx: Ctx&, res: http::Response&, body: u8[>..]&) -> bool {
    let ct, has = http::header(req, "content-type");
    var boundary: u8[>..] = [];
    if !has || !param_value(ct, "boundary", boundary) || boundary.len == 0 || boundary.len > 70 {
        multipart_fail(res, 400);
        return false;
    }
    var fd: i32 = -1;
    if ctx.spool.len > 0 {
        fd = c_up_open_read(ctx.spool);
        if fd < 0 { multipart_fail(res, 500); return false; }
    }
    let status = parse_multipart(fd, req.body, boundary, ctx, body);
    if fd >= 0 { c_up_close(fd); }
    if status != 0 {
        body.clear();
        multipart_fail(res, status);
        return false;
    }
    return true;
}

// The first non-empty file sent under this field name. Only ctx.uploads is searched, never a value in the body.
// Required and missing or empty: "Required." Optional and missing: true, out left alone.
fn form_upload(ctx: const Ctx&, field: const u8[:], out: Upload&, errs: FieldErrors&, required: bool) -> bool {
    for i in ctx.uploads.len {
        if ctx.uploads[i].field == field && ctx.uploads[i].size > 0 {
            out = ctx.uploads[i];
            return true;
        }
    }
    if required { add_error(errs, field, "Required."); return false; }
    return true;
}

// Moves the file to dest and never overwrites; false when dest exists or the move fails.
// A link and unlink, or a copy where the two are on different file systems.
fn save_upload(up: const Upload&, dest: const u8[:]) -> bool {
    if up.path.len == 0 || dest.len == 0 { return false; }
    return c_up_save(up.path, dest) != 0;
}

// Appends a name safe to use as a file name: the part after the last / or \, bytes outside A-Z a-z 0-9 . _ - become _,
// leading dots are dropped, at most 100 bytes; "file" when nothing is left.
fn safe_name(out: u8[>..]&, filename: const u8[:]) {
    var start = 0;
    for i in filename.len {
        if filename[i] == '/' || filename[i] == '\\' { start = i + 1; }
    }
    var n = 0;
    for i in start..filename.len {
        if n >= 100 { break; }
        let c = filename[i];
        if n == 0 && c == '.' { continue; }
        let ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        out.push(if ok { c } else { '_' });
        n += 1;
    }
    if n == 0 { out.append("file"); }
}

// The content type the bytes show: image/png, image/jpeg, image/gif, image/webp, application/pdf; "" for anything
// else. SVG is never sniffed as an image: it can carry script.
fn sniff_bytes(h: const u8[:]) -> const u8[:] {
    if h.len >= 8 && h[0] == 137 && h[1] == 'P' && h[2] == 'N' && h[3] == 'G' && h[4] == 13 && h[5] == 10 && h[6] == 26 && h[7] == 10 {
        return "image/png";
    }
    if h.len >= 3 && h[0] == 255 && h[1] == 216 && h[2] == 255 { return "image/jpeg"; }
    if h.len >= 6 && (h[..6] == "GIF87a" || h[..6] == "GIF89a") { return "image/gif"; }
    if h.len >= 12 && h[..4] == "RIFF" && h[8..12] == "WEBP" { return "image/webp"; }
    if h.len >= 5 && h[..5] == "%PDF-" { return "application/pdf"; }
    return "";
}

// sniff_bytes of the file's first bytes; "" when there is no file or it cannot be read.
fn sniff(up: const Upload&) -> const u8[:] {
    if up.path.len == 0 { return ""; }
    let fd = c_up_open_read(up.path);
    if fd < 0 { return ""; }
    var head: u8[>..] = [];
    c_up_pread(fd, 0, 16, head);
    c_up_close(fd);
    return sniff_bytes(head);
}

// Checks size and sniffed type (not the client's claims) against max_bytes and types, e.g. ["image/png", "image/jpeg"].
// Nothing to check, and true, when no file was sent. Does nothing when the field already has an error.
fn check_upload(errs: FieldErrors&, field: const u8[:], up: const Upload&, max_bytes: i64, types: const u8[:][:]) -> bool {
    if has_error(errs, field) { return false; }
    if up.path.len == 0 { return true; }
    if up.size > max_bytes { add_error(errs, field, "The file is too large."); return false; }
    let t = sniff(up);
    if t.len > 0 {
        for ty in types { if ty == t { return true; } }
    }
    add_error(errs, field, "This file type is not allowed.");
    return false;
}
