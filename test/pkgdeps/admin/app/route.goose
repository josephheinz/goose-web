import std;
import net.http;
import gweb;
import admin.who;

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    gweb::json(res, http::Status.Ok);
    format(res.body, "{\"doubled\":", admin::doubled(), "}");
}
