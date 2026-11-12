import std;
import net.http;
import web;
import lib.shop;
import lib.shopdb;

struct Props { p: shopdb::Product }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    let id, ok = web::param_int(ctx, "id");
    var props = Props { .. };
    if !ok || !shopdb::product(id, props.p) { web::not_found(ctx); return props; }
    ctx.title.append(props.p.name);
    return props;
}
