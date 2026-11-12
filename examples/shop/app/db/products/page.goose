import std;
import net.http;
import web;
import lib.shop;
import lib.shopdb;

struct Props { ok: bool, items: shopdb::Product[>..] }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    ctx.title.append("Products");
    var props = Props { ok: false, items: [] };
    props.ok = shopdb::all(props.items);
    return props;
}
