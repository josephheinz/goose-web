import std;
import net.http;
import web;
import web.form;
import web.valid;
import web.upload;

const MAX_UPLOAD = 200000;

struct UploadForm {
    title: u8[..80] = "",
    photo: web::Upload,
}

struct Props { form: UploadForm, errs: web::FieldErrors }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    ctx.title.append("Upload");
    return Props { form: UploadForm { .. }, errs: web::no_errors() };
}

// Saves into $GW_SAVE_DIR (the suite sets it), or ./saved.
fn POST(req: const http::Request&, ctx: web::Ctx&) -> Props {
    var p = load(req, ctx);
    if !decode(req, ctx, p.form, p.errs) {
        web::unprocessable(ctx);
        return p;
    }
    var dir: u8[>..] = [];
    if !env("GW_SAVE_DIR", dir) || dir.len == 0 { dir.clear(); dir.append("saved"); }
    var name: u8[>..] = [];
    web::safe_name(name, p.form.photo.filename);
    var dest: u8[>..] = [];
    format(dest, dir, "/", name);
    if !web::save_upload(p.form.photo, dest) {
        web::add_error(p.errs, "photo", "Could not save the file.");
        web::unprocessable(ctx);
        return p;
    }
    web::redirect(ctx, "/thanks", 303);
    return p;
}
