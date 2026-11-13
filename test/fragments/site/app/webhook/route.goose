import std;
import net.http;
import gweb;

const CSRF = false;

fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    http::text(res, http::Status.Ok, "hook\n");
}
