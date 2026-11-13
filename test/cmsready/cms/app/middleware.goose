import std;
import net.http;
import gweb;
import gweb.auth.session;

// Every page of the package, and of any module mounted below it, needs a login, except the login page and its post.
fn before(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) -> bool {
    if starts_with(req.target, "/admin/login") { return true; }
    return gweb::require_login(req, ctx, res, "/admin/login");
}

fn after(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    http::set_header(res, "X-Admin", "1");
}
