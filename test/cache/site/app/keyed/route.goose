import std;
import net.http;
import gweb;
import gweb.http.cache;

// Cached under host + path with no TTL: it lasts until gweb::epoch_bump() (DESIGN-ADDENDUM-19, D7).
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    let host, ok = http::header(req, "host");
    var key: u8[>..] = [];
    format(key, trim(host), "\n", req.target);
    if gweb::cache_serve_key(req, ctx, res, key) { return; }
    let r, sent = state::ask(ctx, state::Msg.Next);
    var s: u8[>..] = [];
    format(s, "keyed n=", r.n);
    http::text(res, http::Status.Ok, s);
    gweb::cache_store_key(req, ctx, res, key, 0);
}
