import std;
import net.http;
import gweb;
import gweb.forms.form;
import gweb.auth.rate;
import gweb.auth.session;

// One user, "admin". The hash is "correct horse" at 1000 iterations (the real default is 600000).
const ADMIN_HASH = "$pbkdf2-sha256$1000$Wjwem30gT2ihssPU5fYHGA$gapDbCGG-1W63Nset3FpueDTGSkD_VbvmiUDp-ewQQA";

fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    var username: u8[>..] = [];
    var password: u8[>..] = [];
    var next: u8[>..] = [];
    gweb::form(req, "username", username);
    gweb::form(req, "password", password);
    gweb::form(req, "next", next);
    if !gweb::rate_limit(req, ctx, res, "cms-login", 20, 60) { return; }
    let known = username == "admin";
    if !gweb::password_verify(if known { ADMIN_HASH } else { "" }, password) || !known {
        gweb::redirect(ctx, "/admin/login?error=1", 303);
        return;
    }
    if !gweb::login(req, ctx, res, 1, 1) { return; }
    gweb::redirect(ctx, gweb::safe_next(next, "/admin"), 303);
}
