import std;
import net.http;
import web;
import web.valid;

struct ApiForm {
    photo: web::Upload,
    title: u8[..80] = "",
}

// 200 {"ok":true,"size":N}, or 422 {"errors":{...}}. No MAX_UPLOAD: only --max-upload limits this route.
fn POST(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    var f = ApiForm { .. };
    var errs = web::no_errors();
    if !decode(req, ctx, f, errs) {
        web::errors_json(res, errs);
        return;
    }
    http::json_reply(res, http::Status.Ok);
    format(res.body, "{\"ok\":true,\"size\":", f.photo.size, "}\n");
}
