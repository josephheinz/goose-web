import std;
import net.http;
import web;
import web.sitemap;

fn entries(req: const http::Request&, ctx: web::Ctx&, s: web::Sitemap&) {
    web::sitemap_add(s, "/post/1?x=1&y=2", "2026-01-15");
}
