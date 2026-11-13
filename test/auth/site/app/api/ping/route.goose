import std;
import net.http;
import gweb;

const CSRF = false;

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    http::json_reply(res, http::Status.Ok);
    res.body.append("{\"ok\":true}");
}

fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    http::json_reply(res, http::Status.Ok);
    res.body.append("{\"posted\":true}");
}
