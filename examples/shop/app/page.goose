import std;
import net.http;
import web;
import lib.catalog;
import lib.shop;

struct Props { count: i64 }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    ctx.title.append("Home");
    return Props { count: catalog::ITEMS.len };
}
