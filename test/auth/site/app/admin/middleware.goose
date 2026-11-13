import std;
import net.http;
import gweb;
import gweb.auth.session;

// The user row's session version; a real app reads it from its database.
const USER_VER = 1;

fn before(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) -> bool {
    if !gweb::require_login(req, ctx, res, "/login") { return false; }
    if ctx.session.ver != USER_VER {
        gweb::logout(req, ctx);
        gweb::redirect(ctx, "/login", 303);
        return false;
    }
    return true;
}
