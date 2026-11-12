import std;
import net.http;
import web;
import web.form;
import web.valid;

struct QuickForm {
    email: u8[..200],
    name: u8[..80] = "",
}

struct Props { form: QuickForm, errs: web::FieldErrors, done: bool }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    ctx.title.append("Quick");
    return Props { form: QuickForm { .. }, errs: web::no_errors(), done: false };
}

fn POST(req: const http::Request&, ctx: web::Ctx&) -> Props {
    var p = load(req, ctx);
    if !decode(req, ctx, p.form, p.errs) || !web::check_email(p.errs, "email", p.form.email) {
        web::unprocessable(ctx);
        return p;
    }
    p.done = true;
    return p;
}
