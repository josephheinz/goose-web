import std;
import net.http;
import web;

fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    web::json(res, http::Status.Ok);
    res.body.append("{\"hello\":\"world\"}");
}
