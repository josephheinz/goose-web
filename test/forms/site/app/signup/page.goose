import std;
import net.http;
import gweb;
import gweb.forms.form;
import gweb.forms.valid;

struct SignupForm {
    email: u8[..200],
    name: u8[..80],
    age: i64,
    newsletter: bool,
    note: u8[..500] = "",       // optional: it has a default
}

struct Props { form: SignupForm, errs: gweb::FieldErrors }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    ctx.title.append("Sign up");
    return Props { form: SignupForm { .. }, errs: gweb::no_errors() };
}

fn POST(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    var p = load(req, ctx);
    if !decode(req, ctx, p.form, p.errs) || !gweb::check_email(p.errs, "email", p.form.email) {
        gweb::unprocessable(ctx);
        return p;
    }
    gweb::redirect(ctx, "/thanks", 303);
    return p;
}
