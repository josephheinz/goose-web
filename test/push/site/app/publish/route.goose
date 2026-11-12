import std;
import net.http;
import web;
import web.push;

const CSRF = false;

fn POST(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    var sse: u8[>..] = [];
    format(sse, "data: ", req.body, "\n\n");
    web::publish(ctx, "news", sse);
    web::publish(ctx, "chat", req.body);
    http::text(res, http::Status.Ok, "sent\n");
}
