import std;
import net.http;
import web;
import web.push;

fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    web::websocket(req, ctx, res, "chat", "good.example");
}
