import std;
import net.http;
import gweb;
import gweb.site.meta;
import Brace;
import lib.util;
struct Props { b: Brace::State, url: const u8[:] }
fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    var p = Props { b: Brace::State { .. }, url: "/x.js?a=1&b=2" };
    ctx.title.append("Home & Co");
    gweb::meta_description(ctx, "Fresh \"bread\" & more");
    gweb::meta_canonical(ctx, "/about?x=1&y=2");
    gweb::meta_image(ctx, "/img/logo.png");
    gweb::meta_robots(ctx, "noindex, nofollow");
    p.b.n = 5; p.b.t.append("hi <b>");
    return p;
}
