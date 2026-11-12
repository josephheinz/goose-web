import std;
import net.http;
import web;
import web.push;

fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    res.content_type.clear();
    res.content_type.append("text/event-stream");
    web::subscribe(req, ctx, res, "news", ": ping\n\n");
}
