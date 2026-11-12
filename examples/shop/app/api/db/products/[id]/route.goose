import std;
import net.http;
import web;
import lib.shopdb;

fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    let id, ok = web::param_int(ctx, "id");
    if !ok { http::json_error(res, http::Status.BadRequest, "id must be an integer"); return; }
    var p = shopdb::Product { .. };
    if !shopdb::product(id, p) { http::json_error(res, http::Status.NotFound, "product not found"); return; }
    web::json(res, http::Status.Ok);
    shopdb::product_json(res.body, p);
}
