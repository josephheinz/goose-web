import std;
import net.http;
import gweb;
import gweb.http.cache;

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    gweb::epoch_bump();
    http::text(res, http::Status.Ok, "bumped");
}
