import std;
import net.http;
import gweb;
import gweb.http.files;
import cms.store;

// /media/KEY/NAME: a file the admin uploaded. The key changes when a file is replaced, so the URL is immutable.
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    var rel: u8[>..] = [];
    format(rel, gweb::param(ctx, "key"), "/", gweb::param(ctx, "name"));
    var opts = gweb::FileOptions { .. };
    opts.immutable = true;
    gweb::send_file(req, ctx, res, cms::MEDIA, rel, opts);
}
