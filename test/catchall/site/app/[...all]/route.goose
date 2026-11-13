import std;
import net.http;
import gweb;

const CSRF = false;

fn reply(ctx: gweb::Ctx&, res: http::Response&) {
    var s: u8[>..] = [];
    format(s, "all:", gweb::param(ctx, "all"));
    http::text(res, http::Status.Ok, s);
}

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) { reply(ctx, res); }

fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) { reply(ctx, res); }
