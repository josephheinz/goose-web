import std;
import net.http;
import web;
import web.form;
import web.rate;
import web.session;

// One user. The hash is "correct horse" at 1000 iterations (the real default is 600000).
const ADMIN_HASH = "$pbkdf2-sha256$1000$Wjwem30gT2ihssPU5fYHGA$gapDbCGG-1W63Nset3FpueDTGSkD_VbvmiUDp-ewQQA";

// A page's POST cannot refuse with a 429 (the page would render over it), so login is a route.
fn POST(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    var username: u8[>..] = [];
    var password: u8[>..] = [];
    var next: u8[>..] = [];
    web::form(req, "username", username);
    web::form(req, "password", password);
    web::form(req, "next", next);
    if !web::rate_limit(req, ctx, res, "login", 10, 60) { return; }
    if !web::rate_limit_key(ctx, res, "login-user", username, 5, 60) { return; }
    let known = username == "admin";
    if !web::password_verify(if known { ADMIN_HASH } else { "" }, password) || !known {
        var to: u8[>..] = [];
        to.append("/login?error=1");
        if next.len > 0 { to.append("&next="); web::pct_encode(to, next); }
        web::redirect(ctx, to, 303);
        return;
    }
    if !web::login(req, ctx, res, 1, 1) { return; }
    web::redirect(ctx, web::safe_next(next, "/admin"), 303);
}
