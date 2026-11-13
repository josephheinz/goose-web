import std;
import net.http;
import gweb;
import gweb.auth.session;

// Every page of the package, and of any module mounted below it, needs a login, except the login page and its post.
// The package does not know where it is mounted: cms::MOUNT (written by gweb) says, "/admin" here.
fn before(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) -> bool {
    var login: u8[>..] = [];
    format(login, cms::MOUNT, "/login");
    if starts_with(req.target, login) { return true; }
    return gweb::require_login(req, ctx, res, login);
}

fn after(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    http::set_header(res, "X-Admin", "1");
}
