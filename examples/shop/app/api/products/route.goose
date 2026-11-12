import std;
import net.http;
import web;
import lib.catalog;
import lib.shop;

fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    web::json(res, http::Status.Ok);
    res.body.push('[');
    for p, i in catalog::ITEMS {
        if i > 0 { res.body.push(','); }
        shop::product_json(res.body, p);
    }
    res.body.push(']');
}
