import std;
import net.http;
import gweb;

fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    http::text(res, http::Status.Ok, "saved\n");
}
