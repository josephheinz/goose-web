import std;
import net.http;
import web;
import web.session;

// The user row's session version; a real app reads it from its database.
const USER_VER = 1;

fn before(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) -> bool {
    if !web::require_login(req, ctx, res, "/login") { return false; }
    if ctx.session.ver != USER_VER {
        web::logout(req, ctx);
        web::redirect(ctx, "/login", 303);
        return false;
    }
    return true;
}
