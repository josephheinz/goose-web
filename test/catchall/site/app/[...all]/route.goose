import std;
import net.http;
import web;

const CSRF = false;

fn reply(ctx: web::Ctx&, res: http::Response&) {
    var s: u8[>..] = [];
    format(s, "all:", web::param(ctx, "all"));
    http::text(res, http::Status.Ok, s);
}

fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) { reply(ctx, res); }

fn POST(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) { reply(ctx, res); }
