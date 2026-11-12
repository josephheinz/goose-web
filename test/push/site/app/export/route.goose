import std;
import net.http;
import web;
import web.stream;

fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    res.content_type.clear();
    res.content_type.append("text/plain; charset=utf-8");
    var s = web::stream_begin(req, ctx, res);
    web::write(s, "one\n");
    web::write(s, "two\n");
    web::write(s, "three\n");
    web::end(ctx, s);
}
