// Part of gweb. Import with `import gweb.site.meta;`.

namespace gweb;

import std;
import os;
import net;
import net.http;
import gweb;
import site.template;

// The longest prefix of s that fits max bytes without splitting a UTF-8 sequence.
fn _utf8_cut(s: const u8[:], max: i64) -> i64 {
    if s.len <= max { return s.len; }
    var n = max;
    while n > 0 && s[n] >= 128 && s[n] < 192 { n -= 1; }
    return n;
}

fn meta_description(ctx: Ctx&, s: const u8[:]) {
    ctx.meta.description.clear();
    ctx.meta.description.append(s[.._utf8_cut(s, 320)]);
}

fn meta_canonical(ctx: Ctx&, url: const u8[:]) {
    ctx.meta.canonical.clear();
    ctx.meta.canonical.append(url[.._utf8_cut(url, 512)]);
}

fn meta_image(ctx: Ctx&, url: const u8[:]) {
    ctx.meta.image.clear();
    ctx.meta.image.append(url[.._utf8_cut(url, 512)]);
}

fn meta_robots(ctx: Ctx&, s: const u8[:]) {
    ctx.meta.robots.clear();
    ctx.meta.robots.append(s[.._utf8_cut(s, 64)]);
}

// SITE_URL wins because Host comes from the client; the fallback is for development.
fn site_url(req: const http::Request&, out: u8[>..]&) {
    var e: u8[>..] = [];
    if env("SITE_URL", e) {
        var t: const u8[:] = trim(e);
        while t.len > 0 && t[t.len - 1] == '/' { t = t[..t.len - 1]; }
        if t.len > 0 { out.append(t); return; }
    }
    let proto, has_proto = http::header(req, "x-forwarded-proto");
    out.append(if has_proto && trim(proto) == "https" { "https" } else { "http" });
    out.append("://");
    let host, has_host = http::header(req, "host");
    if has_host { out.append(trim(host)); }
}

fn _meta_url(out: u8[>..]&, req: const http::Request&, url: const u8[:]) {
    var abs: u8[>..] = [];
    if url.len > 0 && url[0] == '/' { site_url(req, abs); }
    abs.append(url);
    escape(out, abs);
}

// One tag per line, no newline after the last, so the layout line holding @meta() stays one line.
fn _render_meta(out: u8[>..]&, req: const http::Request&, ctx: const Ctx&) {
    var first = true;
    if ctx.meta.description.len > 0 {
        out.append("<meta name=\"description\" content=\""); escape(out, ctx.meta.description); out.append("\">");
        first = false;
    }
    if ctx.meta.canonical.len > 0 {
        if !first { out.push('\n'); }
        out.append("<link rel=\"canonical\" href=\""); _meta_url(out, req, ctx.meta.canonical); out.append("\">");
        first = false;
    }
    if ctx.meta.robots.len > 0 {
        if !first { out.push('\n'); }
        out.append("<meta name=\"robots\" content=\""); escape(out, ctx.meta.robots); out.append("\">");
        first = false;
    }
    if ctx.title.len > 0 {
        if !first { out.push('\n'); }
        out.append("<meta property=\"og:title\" content=\""); escape(out, ctx.title); out.append("\">");
        first = false;
    }
    if ctx.meta.description.len > 0 {
        if !first { out.push('\n'); }
        out.append("<meta property=\"og:description\" content=\""); escape(out, ctx.meta.description); out.append("\">");
        first = false;
    }
    if ctx.meta.canonical.len > 0 {
        if !first { out.push('\n'); }
        out.append("<meta property=\"og:url\" content=\""); _meta_url(out, req, ctx.meta.canonical); out.append("\">");
        first = false;
    }
    if ctx.meta.image.len > 0 {
        if !first { out.push('\n'); }
        out.append("<meta property=\"og:image\" content=\""); _meta_url(out, req, ctx.meta.image); out.append("\">\n");
        out.append("<meta name=\"twitter:card\" content=\"summary_large_image\">");
    }
}
