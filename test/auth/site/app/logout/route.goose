import std;
import net.http;
import gweb;
import gweb.auth.session;

fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    gweb::logout(req, ctx);
    gweb::redirect(ctx, "/login", 303);
}
