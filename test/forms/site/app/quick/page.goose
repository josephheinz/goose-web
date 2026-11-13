import std;
import net.http;
import gweb;
import gweb.forms.form;
import gweb.forms.valid;

struct QuickForm {
    email: u8[..200],
    name: u8[..80] = "",
}

struct Props { form: QuickForm, errs: gweb::FieldErrors, done: bool }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    ctx.title.append("Quick");
    return Props { form: QuickForm { .. }, errs: gweb::no_errors(), done: false };
}

fn POST(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    var p = load(req, ctx);
    if !decode(req, ctx, p.form, p.errs) || !gweb::check_email(p.errs, "email", p.form.email) {
        gweb::unprocessable(ctx);
        return p;
    }
    p.done = true;
    return p;
}
