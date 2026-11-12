import std;
import net.http;
import web;
import web.session;

fn POST(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    web::logout(req, ctx);
    web::redirect(ctx, "/login", 303);
}
