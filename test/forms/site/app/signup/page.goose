import std;
import net.http;
import web;
import web.form;
import web.valid;

struct SignupForm {
    email: u8[..200],
    name: u8[..80],
    age: i64,
    newsletter: bool,
    note: u8[..500] = "",       // optional: it has a default
}

struct Props { form: SignupForm, errs: web::FieldErrors }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    ctx.title.append("Sign up");
    return Props { form: SignupForm { .. }, errs: web::no_errors() };
}

fn POST(req: const http::Request&, ctx: web::Ctx&) -> Props {
    var p = load(req, ctx);
    if !decode(req, ctx, p.form, p.errs) || !web::check_email(p.errs, "email", p.form.email) {
        web::unprocessable(ctx);
        return p;
    }
    web::redirect(ctx, "/thanks", 303);
    return p;
}
