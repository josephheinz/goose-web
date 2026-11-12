// Part of goose-web. Import with `import web.testing;`.

namespace web;

import std;
import net;
import net.http;
import web;

let TEST_CSRF = "00000000000000000000000000000000";
let FORM_HEX = "0123456789ABCDEF";

// headers: extra lines for the next request only. cookies: the jar, "name=value; name=value".
struct Tester { failures: i64 = 0, checks: i64 = 0, name: u8[..128] = "",
                auto_csrf: bool = true, headers: u8[..2048] = "",
                cookies: u8[..4096] = "" }

// The value of a jar cookie; "" when absent.
fn jar_get(t: const Tester&, name: const u8[:]) -> const u8[:], bool {
    var i = 0;
    while i <= t.cookies.len {
        var j = i;
        while j < t.cookies.len && t.cookies[j] != ';' { j += 1; }
        let key, value, has = split_once(trim(t.cookies[i..j]), '=');
        if has && key == name { return value, true; }
        i = j + 1;
    }
    return "", false;
}

// Drops name from the jar, then adds name=value when keep is set.
fn jar_put(t: Tester&, name: const u8[:], value: const u8[:], keep: bool) {
    var out: u8[>..] = [];
    var i = 0;
    while i <= t.cookies.len {
        var j = i;
        while j < t.cookies.len && t.cookies[j] != ';' { j += 1; }
        let ent = trim(t.cookies[i..j]);
        let key, rest, has = split_once(ent, '=');
        if ent.len > 0 && !(has && key == name) {
            if out.len > 0 { out.append("; "); }
            out.append(ent);
        }
        i = j + 1;
    }
    if keep {
        if out.len > 0 { out.append("; "); }
        format(out, name, "=", value);
    }
    if out.len > t.cookies.cap { return; }
    t.cookies.clear();
    t.cookies.append(out);
}

// True when attrs holds Max-Age=0 and not Max-Age=0<digit>.
fn max_age_zero(attrs: const u8[:]) -> bool {
    let i = find(attrs, "Max-Age=0");
    if i < 0 { return false; }
    let end = i + 9;
    return end >= attrs.len || attrs[end] < '0' || attrs[end] > '9';
}

fn jar_update(t: Tester&, headers: const u8[:]) {
    var i = 0;
    while i < headers.len {
        var j = i;
        while j < headers.len && headers[j] != '\n' { j += 1; }
        let line = trim(headers[i..j]);
        i = j + 1;
        if line.len < 11 || !http::eq_nocase(line[..11], "set-cookie:") { continue; }
        let rest = trim(line[11..]);
        let pair, attrs, has_attrs = split_once(rest, ';');
        let first = if has_attrs { pair } else { rest };
        let name, value, has = split_once(first, '=');
        if !has || name.len == 0 { continue; }
        jar_put(t, name, value, !(has_attrs && max_age_zero(attrs)));
    }
}

// Runs one request through the app's dispatcher (D) and static files (S), with no socket.
fn test_send<D, S>(t: Tester&, method: const u8[:], target: const u8[:], body: const u8[:], content_type: const u8[:]) -> http::Response {
    if t.auto_csrf && method != "GET" {
        let have, has = jar_get(t, "gw_csrf");
        if !has { jar_put(t, "gw_csrf", TEST_CSRF, true); }
    }
    var raw: u8[>..] = [];
    format(raw, method, " ", target, " HTTP/1.1\r\nHost: test\r\n");
    if t.cookies.len > 0 { format(raw, "Cookie: ", t.cookies, "\r\n"); }
    if t.auto_csrf && method != "GET" {
        let tok, has = jar_get(t, "gw_csrf");
        if has { format(raw, "X-CSRF-Token: ", tok, "\r\n"); }
    }
    if body.len > 0 { format(raw, "Content-Type: ", content_type, "\r\nContent-Length: ", body.len, "\r\n"); }
    if t.headers.len > 0 {
        raw.append(t.headers);
        if raw[raw.len - 1] != '\n' { raw.append("\r\n"); }
        t.headers.clear();
    }
    raw.append("\r\n");
    raw.append(body);

    var res = http::new_response();
    // req points into raw, so raw stays alive until the reply is built
    let req, parsed = http::parse_request(raw);
    if parsed != http::Read.Ready {
        expect(t, false, "test request did not parse");
        http::json_error(res, http::Status.BadRequest, "test request did not parse");
        return res;
    }
    var cfg = default_config();
    cfg.workers = 1;
    let static_index, dev = respond(req, 0, -1, cfg, res, D);
    if static_index >= 0 { res.body.append(S(static_index)); }
    if req.method == http::Method.Head { res.body.clear(); }
    jar_update(t, res.headers);
    return res;
}

fn expect(t: Tester&, ok: bool, what: const u8[:]) {
    t.checks += 1;
    if !ok {
        t.failures += 1;
        print("FAIL ", t.name, ": ", what);
    }
}

fn expect_status(t: Tester&, res: const http::Response&, code: i64) {
    var msg: u8[..64] = "";
    format(msg, "status ", http::code(res.status), ", want ", code);
    expect(t, http::code(res.status) == code, msg);
}

fn expect_contains(t: Tester&, text: const u8[:], needle: const u8[:]) {
    var msg: u8[>..] = [];
    format(msg, "'", text, "' lacks '", needle, "'");
    expect(t, find(text, needle) >= 0, msg);
}

fn expect_header(t: Tester&, res: const http::Response&, name: const u8[:], value: const u8[:]) {
    let got, has = header_of(res, name);
    var msg: u8[>..] = [];
    format(msg, "header ", name, " is '", got, "', want '", value, "'");
    expect(t, has && got == value, msg);
}

// The first header with this name (case-insensitive); has is false when absent.
fn header_of(res: const http::Response&, name: const u8[:]) -> const u8[:], bool {
    let v, has = http::find_header(res.headers, name);
    return v, has;
}

// Appends &name=value, URL-encoded (no leading & when out is empty).
fn form_field(out: u8[>..]&, name: const u8[:], value: const u8[:]) {
    if out.len > 0 { out.push('&'); }
    form_encode(out, name);
    out.push('=');
    form_encode(out, value);
}

fn form_encode(out: u8[>..]&, s: const u8[:]) {
    for c in s {
        if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~' {
            out.push(c);
        } else {
            out.push('%');
            out.push(FORM_HEX[c >> 4]);
            out.push(FORM_HEX[c & 15]);
        }
    }
}
