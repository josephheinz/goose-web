import std;
import net.http;
import web;
import lib.shop;
import lib.shopdb;

struct Props { ok: bool, items: shopdb::Product[>..] }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    ctx.title.append("Home");
    var props = Props { ok: false, items: [] };
    props.ok = shopdb::featured(props.items);
    return props;
}
