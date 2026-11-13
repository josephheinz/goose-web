import std;
import net.http;
import gweb;

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    gweb::json(res, http::Status.Ok);
    res.body.append("{\"hello\":\"world\"}");
}
