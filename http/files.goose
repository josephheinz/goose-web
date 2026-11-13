// Part of gweb. Import with `import gweb.http.files;`.
// Serves a file from disk under a root: Content-Type from the extension, ETag, Last-Modified and 304, HEAD, and a stream for big files.

namespace gweb;

import std;
import net;
import net.http;
import gweb;
import http.stream;

extern fn c_file_open_in(root: const u8[:], rel: const u8[:], size: i64&, mtime_ns: i64&) -> i32 = "gweb_file_open_in";
extern fn c_file_pread(fd: i32, off: i64, n: i64, out: u8[>..]&) -> i64 = "gweb_file_pread";
extern fn c_file_close(fd: i32) = "gweb_file_close";

let FILE_WINDOW = 262144;      // bytes read and written at a time when streaming
let FILE_MAX_REL = 1024;

struct FileOptions {
    immutable: bool = false,         // Cache-Control: immutable for one year: for a URL whose name changes with the bytes
    download: bool = false,          // Content-Disposition: attachment
    filename: u8[..200] = "",        // the name Content-Disposition shows; "" is the file's own name
    content_type: u8[..120] = "",    // "" is chosen from the extension
    stream_over: i64 = 1048576,      // files above this many bytes are streamed in windows, not read into memory
}

// ---------------------------------------------------------------- HTTP dates

let HTTP_DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
let HTTP_MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

fn _pad2(out: u8[>..]&, n: i64) { out.push('0' + (n / 10) as u8); out.push('0' + (n % 10) as u8); }

// Appends secs (Unix time, 0 or more) as an HTTP date: Sun, 06 Nov 1994 08:49:37 GMT.
fn _http_date(out: u8[>..]&, secs: i64) {
    let t = max(secs, 0);
    let days = t / 86400;
    let rem = t % 86400;
    // Howard Hinnant's civil_from_days.
    let z = days + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + (if month <= 2 { 1 } else { 0 });
    out.append(HTTP_DAYS[(days + 4) % 7]);
    out.append(", ");
    _pad2(out, day);
    out.push(' ');
    out.append(HTTP_MONTHS[month - 1]);
    out.push(' ');
    format(out, year);
    out.push(' ');
    _pad2(out, rem / 3600);
    out.push(':');
    _pad2(out, (rem % 3600) / 60);
    out.push(':');
    _pad2(out, rem % 60);
    out.append(" GMT");
}

fn _two_digits(s: const u8[:], at: i64) -> i64 {
    if s[at] < '0' || s[at] > '9' || s[at + 1] < '0' || s[at + 1] > '9' { return -1; }
    return ((s[at] - 48) as i64) * 10 + (s[at + 1] - 48);
}

// Unix seconds for an IMF-fixdate (Sun, 06 Nov 1994 08:49:37 GMT) from 1970 on; false for anything else, which a
// conditional request then ignores.
fn _parse_http_date(text: const u8[:]) -> i64, bool {
    let s = trim(text);
    if s.len != 29 || s[3] != ',' || s[4] != ' ' || s[7] != ' ' || s[11] != ' ' || s[16] != ' ' || s[19] != ':' || s[22] != ':' || s[25] != ' ' { return 0, false; }
    if s[26..] != "GMT" { return 0, false; }
    var known = false;
    for d in HTTP_DAYS { if s[..3] == d { known = true; } }
    let day = _two_digits(s, 5);
    var month = 0;
    for m, i in HTTP_MONTHS { if s[8..11] == m { month = i + 1; } }
    let y1 = _two_digits(s, 12);
    let y2 = _two_digits(s, 14);
    let hh = _two_digits(s, 17);
    let mm = _two_digits(s, 20);
    let ss = _two_digits(s, 23);
    if !known || day < 1 || day > 31 || month == 0 || y1 < 0 || y2 < 0 || hh < 0 || hh > 23 || mm < 0 || mm > 59 || ss < 0 || ss > 60 { return 0, false; }
    let year = y1 * 100 + y2;
    if year < 1970 { return 0, false; }
    // days_from_civil
    let y = if month <= 2 { year - 1 } else { year };
    let era = y / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    return days * 86400 + hh * 3600 + mm * 60 + ss, true;
}

// The Content-Type for a file name, by extension; application/octet-stream when unknown.
fn mime_type(file: const u8[:]) -> const u8[:] {
    let dot = rfind(file, ".");
    if dot < 0 { return "application/octet-stream"; }
    let e = file[dot + 1..];
    if e.len > 16 { return "application/octet-stream"; }
    var ext: u8[..16] = "";
    ext.append(e);
    to_lower(ext);
    if ext == "html" || ext == "htm" { return "text/html; charset=utf-8"; }
    if ext == "css" { return "text/css; charset=utf-8"; }
    if ext == "js" || ext == "mjs" { return "text/javascript; charset=utf-8"; }
    if ext == "json" || ext == "map" { return "application/json"; }
    if ext == "txt" || ext == "md" { return "text/plain; charset=utf-8"; }
    if ext == "csv" { return "text/csv; charset=utf-8"; }
    if ext == "xml" { return "application/xml"; }
    if ext == "svg" { return "image/svg+xml"; }
    if ext == "png" { return "image/png"; }
    if ext == "jpg" || ext == "jpeg" { return "image/jpeg"; }
    if ext == "gif" { return "image/gif"; }
    if ext == "webp" { return "image/webp"; }
    if ext == "avif" { return "image/avif"; }
    if ext == "ico" { return "image/x-icon"; }
    if ext == "woff2" { return "font/woff2"; }
    if ext == "woff" { return "font/woff"; }
    if ext == "pdf" { return "application/pdf"; }
    if ext == "zip" { return "application/zip"; }
    if ext == "mp4" { return "video/mp4"; }
    if ext == "webm" { return "video/webm"; }
    if ext == "mp3" { return "audio/mpeg"; }
    if ext == "wasm" { return "application/wasm"; }
    return "application/octet-stream";
}

// True when rel is a safe relative path: no leading '/', no empty segment, no segment that starts with '.'
// (so no `.` or `..`, and no dotfile), no backslash or control byte, at most 1,024 bytes. Pass the decoded path:
// `%2e%2e` arrives here as `..`.
fn file_path_ok(rel: const u8[:]) -> bool {
    if rel.len == 0 || rel.len > FILE_MAX_REL || rel[0] == '/' || rel[rel.len - 1] == '/' { return false; }
    var start = true;
    for c in rel {
        if c < ' ' || c == 127 || c == '\\' { return false; }
        if c == '/' {
            if start { return false; }
            start = true;
            continue;
        }
        if start && c == '.' { return false; }
        start = false;
    }
    return true;
}

// The last segment of a path.
fn _file_base(rel: const u8[:]) -> const u8[:] {
    let s = rfind(rel, "/");
    if s < 0 { return rel; }
    return rel[s + 1..];
}

// Content-Disposition for a download or inline file: an ASCII name for old clients, and filename* (percent-encoded UTF-8) when it differs.
fn _file_disposition(out: u8[>..]&, kind: const u8[:], name: const u8[:]) {
    out.append(kind);
    out.append("; filename=\"");
    var plain = true;
    for c in name {
        if c < ' ' || c >= 127 || c == '"' || c == '\\' || c == '%' { out.push('_'); plain = false; }
        else { out.push(c); }
    }
    out.push('"');
    if !plain {
        out.append("; filename*=UTF-8''");
        let hex = "0123456789ABCDEF";
        for c in name {
            let keep = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_';
            if keep { out.push(c); }
            else if c >= ' ' && c != 127 { out.push('%'); out.push(hex[c >> 4]); out.push(hex[c & 15]); }
        }
    }
}

fn _file_miss(res: http::Response&) -> bool {
    res.status = http::Status.NotFound;
    res.content_type.clear();
    res.content_type.append("text/plain; charset=utf-8");
    res.body.clear();
    res.body.append("Not Found");
    return false;
}

// Sends root/rel. rel is a decoded relative path, such as the tail of a catch-all: `gweb::path_decode(rel, gweb::param(ctx, "path"))`.
// The reply is 200 with the bytes, 304 when If-None-Match matches the ETag (or, with no If-None-Match, when If-Modified-Since is
// not older than the file), or (for HEAD) the head alone. The ETag is made of the file's size and modification time, so no content
// is read to answer 304. Every reply carries Last-Modified.
// Returns false after setting a plain 404 when rel is unsafe (see file_path_ok), names nothing, is not a regular file, or resolves
// outside root (a symlink out of it); the caller may replace that reply. A file above opts.stream_over is sent in windows through
// a stream; a HEAD for it sends the head with its Content-Length and reads nothing.
fn send_file(req: const http::Request&, ctx: Ctx&, res: http::Response&, root: const u8[:], rel: const u8[:], opts: const FileOptions&) -> bool {
    if !file_path_ok(rel) { return _file_miss(res); }
    var size: i64 = 0;
    var mtime: i64 = 0;
    let fd = c_file_open_in(root, rel, size, mtime);
    if fd < 0 { return _file_miss(res); }
    var etag: u8[..64] = "\"";
    format(etag, size, "-", mtime, "\"");
    var ctype: u8[..120] = "";
    if opts.content_type.len > 0 { ctype.append(opts.content_type); } else { ctype.append(mime_type(rel)); }
    let name = _file_base(rel);
    http::set_header(res, "ETag", etag);
    var modified: u8[>..] = [];
    _http_date(modified, mtime / 1000000000);
    http::set_header(res, "Last-Modified", modified);
    http::set_header(res, "Cache-Control", if opts.immutable { "public, max-age=31536000, immutable" } else { "public, max-age=0, must-revalidate" });
    if starts_with(ctype, "text/html") || starts_with(ctype, "image/svg") {
        http::set_header(res, "Content-Security-Policy", "sandbox");   // an uploaded page or SVG must not run scripts on this origin
    }
    if opts.download || opts.filename.len > 0 {
        var cd: u8[>..] = [];
        _file_disposition(cd, if opts.download { "attachment" } else { "inline" }, if opts.filename.len > 0 { opts.filename } else { name });
        http::set_header(res, "Content-Disposition", cd);
    }
    // If-None-Match decides alone when it is present; If-Modified-Since only without it (RFC 9110, section 13.2.2).
    let inm, has = http::header(req, "if-none-match");
    let ims, has_ims = http::header(req, "if-modified-since");
    var fresh = false;
    if has { fresh = find(inm, etag) >= 0 || trim(inm) == "*"; }
    else if has_ims {
        let since, ims_ok = _parse_http_date(ims);
        fresh = ims_ok && mtime / 1000000000 <= since;
    }
    if fresh {
        c_file_close(fd);
        res.status = http::Status.NotModified;
        res.content_type.clear();
        res.body.clear();
        return true;
    }
    res.status = http::Status.Ok;
    res.content_type.clear();
    res.content_type.append(ctype);
    res.body.clear();
    if size <= opts.stream_over || ctx.conn_fd < 0 {
        // In memory: a Content-Length, and what gweb test can see. HEAD reads it too, for the length.
        var off = 0;
        while off < size {
            let n = c_file_pread(fd, off, size - off, res.body);
            if n <= 0 { break; }
            off += n;
        }
        c_file_close(fd);
        if off != size { return _file_miss(res); }
        return true;
    }
    if req.method == http::Method.Head {
        // The head alone, with the length the body would have. stream_begin cannot do this: its head is always chunked.
        c_file_close(fd);
        if !_apply_cookies(ctx, res) { return true; }
        format(res.headers, "Content-Type: ", ctype, "\r\nContent-Length: ", size, "\r\n");
        res.content_type.clear();
        ctx.streamed = true;
        ctx.stream_ended = http::send_head(net::Socket { fd: ctx.conn_fd }, res, if http::wants_keep_alive(req) { "keep-alive" } else { "close" });
        return true;
    }
    var s = stream_begin(req, ctx, res);
    if !s.ok { c_file_close(fd); return true; }
    var off = 0;
    var chunk: u8[>..] = [];
    while off < size && s.ok {
        chunk.clear();
        let n = c_file_pread(fd, off, FILE_WINDOW, chunk);
        if n <= 0 { break; }
        off += n;
        stream_write(s, chunk);
    }
    c_file_close(fd);
    if off != size {
        s.ok = false;
        s.conn.shutdown_write();   // the length was promised by nothing, but a short body must not look complete
        ctx.stream_ended = false;
        return true;
    }
    stream_end(ctx, s);
    return true;
}
