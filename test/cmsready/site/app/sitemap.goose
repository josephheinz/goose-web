import std;
import net.http;
import gweb;
import gweb.site.sitemap;
import cms.store;
import lib.site;

// Each host is its own site: its nodes, under its own base URL.
fn entries(req: const http::Request&, ctx: gweb::Ctx&, s: gweb::Sitemap&) {
    var host: u8[>..] = [];
    site::host_of(req, host);
    var ch = cms::Channel { .. };
    if !cms::channel_by_host(host, ch) { return; }
    var base: u8[>..] = [];
    format(base, "https://", ch.host);
    gweb::sitemap_base(s, base);
    var rows: cms::Row[..32] = [];
    cms::list_nodes(ch.host, rows);
    for r in rows { gweb::sitemap_add(s, r.path); }
}

fn robots(req: const http::Request&, ctx: gweb::Ctx&, out: u8[>..]&) {
    var host: u8[>..] = [];
    site::host_of(req, host);
    out.append("User-agent: *\nDisallow: /admin\n");
    format(out, "Sitemap: https://", host, "/sitemap.xml\n");
}
