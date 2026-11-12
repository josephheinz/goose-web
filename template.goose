// Part of goose-web. Import with `import web.template;`.

namespace web;

import std;
import net;
import net.http;
import web;

let ESCAPED = byte_set("&<>\"'");

fn escape(out: u8[>..]&, s: const u8[:]) {
    var pos = 0;
    loop {
        let k = find_any(s[pos..], ESCAPED);
        if k < 0 { out.append(s[pos..]); return; }
        out.append(s[pos..pos + k]);
        let c = s[pos + k];
        if c == '&' { out.append("&amp;"); }
        else if c == '<' { out.append("&lt;"); }
        else if c == '>' { out.append("&gt;"); }
        else if c == '"' { out.append("&quot;"); }
        else { out.append("&#39;"); }
        pos += k + 1;
    }
}

// {expr}: the value's text, escaped.
fn put(out: u8[>..]&, s: const u8[:]) { escape(out, s); }
fn put(out: u8[>..]&, v: i64) { format(out, v); }
fn put(out: u8[>..]&, v: f64) { format(out, v); }
fn put(out: u8[>..]&, v: bool) { format(out, v); }
fn put<T>(out: u8[>..]&, v: const T&) {
    var tmp: u8[>..] = [];
    format(tmp, v);
    escape(out, tmp);
}

// {#raw expr}: the value's text, unescaped.
fn raw<T>(out: u8[>..]&, v: const T&) { format(out, v); }
// Matches JSON.stringify: " and \ escaped, \b \f \n \r \t, other control bytes as \u00XX. safe also escapes < > & as \u00XX.
fn json_quoted(out: u8[>..]&, s: const u8[:], safe: bool) {
    let hex = "0123456789abcdef";
    out.push('"');
    for c in s {
        if c == '"' { out.append("\\\""); }
        else if c == '\\' { out.append("\\\\"); }
        else if c == '\n' { out.append("\\n"); }
        else if c == '\r' { out.append("\\r"); }
        else if c == '\t' { out.append("\\t"); }
        else if c == 8 { out.append("\\b"); }
        else if c == 12 { out.append("\\f"); }
        else if c < 32 || (safe && (c == '<' || c == '>' || c == '&')) {
            out.append("\\u00"); out.push(hex[c >> 4]); out.push(hex[c & 15]);
        }
        else { out.push(c); }
    }
    out.push('"');
}

// Safe inside <script>.
fn json_text(out: u8[>..]&, s: const u8[:]) { json_quoted(out, s, true); }

// An argument of an on: handler call, inside data-args="[...]".
fn arg(out: u8[>..]&, v: i64) { format(out, v); }
fn arg(out: u8[>..]&, v: bool) { format(out, v); }
fn arg(out: u8[>..]&, v: const u8[:]) {
    var tmp: u8[>..] = [];
    json_quoted(tmp, v, false);
    escape(out, tmp);
}

fn has(a: const u8[:], b: const u8[:]) -> bool { find(a, b) >= 0 }

// The hidden _csrf input a form needs; the value is "" before web::csrf_begin.
fn csrf_field(out: u8[>..]&, ctx: const Ctx&) {
    out.append("<input type=\"hidden\" name=\"_csrf\" value=\"");
    out.append(ctx.csrf);
    out.append("\">");
}

// This page's CSRF token, for a meta tag.
fn csrf_token(ctx: const Ctx&) -> const u8[:] { return ctx.csrf; }
