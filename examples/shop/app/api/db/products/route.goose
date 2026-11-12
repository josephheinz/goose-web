import std;
import net.http;
import web;
import lib.shopdb;

fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    var items: shopdb::Product[>..] = [];
    if !shopdb::all(items) { http::json_error(res, http::Status.InternalServerError, "database error"); return; }
    web::json(res, http::Status.Ok);
    res.body.push('[');
    for p, i in items {
        if i > 0 { res.body.push(','); }
        shopdb::product_json(res.body, p);
    }
    res.body.push(']');
}
