import std;
import net.http;
import gweb;
import gweb.site.sitemap;

// The base is the request's own host, whatever SITE_URL says; the static / entry is added before this runs.
fn entries(req: const http::Request&, ctx: gweb::Ctx&, s: gweb::Sitemap&) {
    let host, ok = http::header(req, "host");
    var base: u8[>..] = [];
    format(base, "https://", trim(host), "/");
    gweb::sitemap_base(s, base);
    gweb::sitemap_add(s, "/p?a=1&b=2");
}

fn robots(req: const http::Request&, ctx: gweb::Ctx&, out: u8[>..]&) {
    let host, ok = http::header(req, "host");
    format(out, "User-agent: *\nDisallow: /private\nSitemap: https://", trim(host), "/sitemap.xml\n");
}
