import std;
import net.http;
import web;
import web.meta;
import Brace;
import lib.util;
struct Props { b: Brace::State, url: const u8[:] }
fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    var p = Props { b: Brace::State { .. }, url: "/x.js?a=1&b=2" };
    ctx.title.append("Home & Co");
    web::meta_description(ctx, "Fresh \"bread\" & more");
    web::meta_canonical(ctx, "/about?x=1&y=2");
    web::meta_image(ctx, "/img/logo.png");
    web::meta_robots(ctx, "noindex, nofollow");
    p.b.n = 5; p.b.t.append("hi <b>");
    return p;
}
