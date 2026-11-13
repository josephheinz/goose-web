import std;
import net.http;
import gweb;
import gweb.auth.session;

fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    gweb::logout(req, ctx);
    var to: u8[>..] = [];
    format(to, cms::MOUNT, "/login");
    gweb::redirect(ctx, to, 303);
}
