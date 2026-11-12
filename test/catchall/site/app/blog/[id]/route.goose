import std;
import net.http;
import web;

fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    var s: u8[>..] = [];
    format(s, "blog-id:", web::param(ctx, "id"));
    http::text(res, http::Status.Ok, s);
}
