import std;
import net.http;
import gweb;
import gweb.forms.form;
import gweb.forms.valid;
import gweb.forms.upload;

const MAX_UPLOAD = 200000;

struct UploadForm {
    title: u8[..80] = "",
    photo: gweb::Upload,
}

struct Props { form: UploadForm, errs: gweb::FieldErrors }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    ctx.title.append("Upload");
    return Props { form: UploadForm { .. }, errs: gweb::no_errors() };
}

// Saves into $GW_SAVE_DIR (the suite sets it), or ./saved.
fn POST(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    var p = load(req, ctx);
    if !decode(req, ctx, p.form, p.errs) {
        gweb::unprocessable(ctx);
        return p;
    }
    var dir: u8[>..] = [];
    if !env("GW_SAVE_DIR", dir) || dir.len == 0 { dir.clear(); dir.append("saved"); }
    var name: u8[>..] = [];
    gweb::safe_name(name, p.form.photo.filename);
    var dest: u8[>..] = [];
    format(dest, dir, "/", name);
    if !gweb::save_upload(p.form.photo, dest) {
        gweb::add_error(p.errs, "photo", "Could not save the file.");
        gweb::unprocessable(ctx);
        return p;
    }
    gweb::redirect(ctx, "/thanks", 303);
    return p;
}
