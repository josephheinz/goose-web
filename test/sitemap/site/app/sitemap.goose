import std;
import net.http;
import gweb;
import gweb.site.sitemap;

fn entries(req: const http::Request&, ctx: gweb::Ctx&, s: gweb::Sitemap&) {
    gweb::sitemap_add(s, "/post/1?x=1&y=2", "2026-01-15");
}
