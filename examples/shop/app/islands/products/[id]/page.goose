import std;
import net.http;
import web;
import lib.catalog;
import lib.shop;
import Qty;

struct Props { p: catalog::Product, qty: Qty::State }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    let id, ok = web::param_int(ctx, "id");
    let i = if ok { shop::find_product(id) } else { -1 };
    if i < 0 { web::not_found(ctx); return Props { .. }; }
    ctx.title.append(catalog::ITEMS[i].name);
    return Props { p: catalog::ITEMS[i], qty: Qty::State { cents: catalog::ITEMS[i].cents, qty: 1 } };
}
