import std;
import net.http;
import web;
import lib.catalog;
import lib.shop;

fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    let id, ok = web::param_int(ctx, "id");
    if !ok { http::json_error(res, http::Status.BadRequest, "id must be an integer"); return; }
    let i = shop::find_product(id);
    if i < 0 { http::json_error(res, http::Status.NotFound, "product not found"); return; }
    web::json(res, http::Status.Ok);
    shop::product_json(res.body, catalog::ITEMS[i]);
}
