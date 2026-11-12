import std;
import net.http;
import web;
import web.push;

fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    var out: u8[>..] = [];
    format(out, "news=", web::subscribers(ctx, "news"), " chat=", web::subscribers(ctx, "chat"), "\n");
    http::text(res, http::Status.Ok, out);
}
