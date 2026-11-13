import std;
import net.http;
import gweb;
import gweb.forms.valid;

struct ApiForm {
    photo: gweb::Upload,
    title: u8[..80] = "",
}

// 200 {"ok":true,"size":N}, or 422 {"errors":{...}}. No MAX_UPLOAD: only --max-upload limits this route.
fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    var f = ApiForm { .. };
    var errs = gweb::no_errors();
    if !decode(req, ctx, f, errs) {
        gweb::errors_json(res, errs);
        return;
    }
    http::json_reply(res, http::Status.Ok);
    format(res.body, "{\"ok\":true,\"size\":", f.photo.size, "}\n");
}
