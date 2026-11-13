import std;
import net.http;
import gweb;
import gweb.site.sitemap;

fn entries(req: const http::Request&, ctx: gweb::Ctx&, s: gweb::Sitemap&) {
    gweb::sitemap_add(s, "/post/1");
}
