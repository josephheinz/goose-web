import std;
import os;
import net.http;
import gweb;
import gweb.forms.upload;
import gweb.forms.valid;
import cms.store;
import cms.msg;

const SITEMAP = false;
const MAX_UPLOAD = 5000000;

struct UploadForm { file: gweb::Upload }
struct Props { rows: cms::MediaRow[..32], err: u8[..200] }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    var p = Props { rows: [], err: "" };
    cms::list_media(p.rows);
    ctx.title.append("Media");
    return p;
}

// The file moves to data/media/KEY/NAME, where the host's /media route serves it; the key comes from the owner.
fn POST(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    var p = load(req, ctx);
    var form = UploadForm { file: gweb::Upload { .. } };
    var errs = gweb::no_errors();
    if !decode(req, ctx, form, errs) { p.err.append("Choose a file."); gweb::unprocessable(ctx); return p; }
    var name: u8[>..] = [];
    gweb::safe_name(name, form.file.filename);
    let r, ok = state::ask(ctx, state::Msg.Cms { m: cms::Msg.MediaAdd { name: copy(name), size: form.file.size } });
    if !ok || !r.cms.ok { gweb::fail(ctx, 500, "Could not register the file."); return p; }
    var dir: u8[>..] = [];
    format(dir, cms::MEDIA, "/m", r.cms.id);
    make_dir(dir);
    var dest: u8[>..] = [];
    format(dest, dir, "/", name);
    if !gweb::save_upload(form.file, dest) { gweb::fail(ctx, 500, "Could not store the file."); return p; }
    gweb::epoch_bump();
    gweb::redirect(ctx, "/admin/media", 303);
    return p;
}
