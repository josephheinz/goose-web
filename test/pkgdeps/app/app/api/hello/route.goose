import std;
import net.http;
import gweb;
import fakelib;

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    gweb::json(res, http::Status.Ok);
    format(res.body, "{\"answer\":", fakelib::answer(), "}");
}
