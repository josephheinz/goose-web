import std;
import net.http;
import web;
import web.errors;

fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    web::fail(ctx, 429, "Slow down.");
}
