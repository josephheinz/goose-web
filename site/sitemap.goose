// Part of gweb. Import with `import gweb.site.sitemap;`.

namespace gweb;

import std;
import net;
import net.http;
import gweb;
import site.template;
import site.meta;

let SITEMAP_MAX_URLS = 50000;
// The protocol's 50 MiB limit; sitemap_add stops short of it so the closing tag always fits.
let SITEMAP_MAX_BYTES = 52428000;
let SITEMAP_MAX_PATH = 2048;

// body holds only the <url> entries; sitemap_reply wraps them, so the cap checks need no header arithmetic.
root struct Sitemap { base: u8[>..], body: u8[>..], count: i64 }

// Fills a Sitemap the caller owns (a root struct cannot be returned): var s = Sitemap { base: [], body: [], count: 0 };
fn sitemap_init(req: const http::Request&, s: Sitemap&) {
    s.base.clear();
    s.body.clear();
    s.count = 0;
    site_url(req, s.base);
}

fn digit(c: u8) -> bool { return c >= '0' && c <= '9'; }

fn lastmod_ok(s: const u8[:]) -> bool {
    if s.len != 10 { return false; }
    for c, i in s {
        if i == 4 || i == 7 { if c != '-' { return false; } }
        else if !digit(c) { return false; }
    }
    let month = (s[5] - '0') * 10 + (s[6] - '0');
    let day = (s[8] - '0') * 10 + (s[9] - '0');
    return month >= 1 && month <= 12 && day >= 1 && day <= 31;
}

// Callers pass the path already percent-encoded: a sitemap's <loc> must be a valid URL, so spaces and raw non-ASCII are refused.
fn sitemap_path_ok(path: const u8[:]) -> bool {
    if path.len == 0 || path.len > SITEMAP_MAX_PATH || path[0] != '/' { return false; }
    for c in path { if c <= 32 || c >= 127 { return false; } }
    return true;
}

// False, with s unchanged, when the path or lastmod is malformed or the sitemap is full.
fn sitemap_add(s: Sitemap&, path: const u8[:], lastmod: const u8[:] = "") -> bool {
    if !sitemap_path_ok(path) { return false; }
    if lastmod.len > 0 && !lastmod_ok(lastmod) { return false; }
    if s.count >= SITEMAP_MAX_URLS { return false; }
    // Worst case: every path byte escapes to six.
    if s.body.len + s.base.len + path.len * 6 + 128 > SITEMAP_MAX_BYTES { return false; }
    s.body.append("<url><loc>");
    escape(s.body, s.base);
    escape(s.body, path);
    s.body.append("</loc>");
    if lastmod.len > 0 { s.body.append("<lastmod>"); s.body.append(lastmod); s.body.append("</lastmod>"); }
    s.body.append("</url>\n");
    s.count += 1;
    return true;
}

fn sitemap_reply(res: http::Response&, s: const Sitemap&) {
    res.status = http::Status.Ok;
    res.content_type.clear();
    res.content_type.append("application/xml; charset=utf-8");
    http::set_header(res, "Cache-Control", "public, max-age=3600");
    res.body.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n");
    res.body.append(s.body);
    res.body.append("</urlset>\n");
}

fn robots_reply(req: const http::Request&, res: http::Response&) {
    res.status = http::Status.Ok;
    res.content_type.clear();
    res.content_type.append("text/plain; charset=utf-8");
    http::set_header(res, "Cache-Control", "public, max-age=3600");
    res.body.append("User-agent: *\nAllow: /\nSitemap: ");
    site_url(req, res.body);
    res.body.append("/sitemap.xml\n");
}
