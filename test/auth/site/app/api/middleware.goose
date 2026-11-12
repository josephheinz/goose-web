import std;
import net.http;
import web;
import web.cors;

fn before(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) -> bool {
    return web::cors(req, ctx, res, web::CorsOptions { origins: "https://ok.example", .. });
}
