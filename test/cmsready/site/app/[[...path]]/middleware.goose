import std;
import net.http;
import gweb;
import gweb.http.cache;
import lib.site;

// One cache entry per host and path, kept until gweb::epoch_bump(): the admin bumps it after every save.
fn before(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) -> bool {
    var key: u8[>..] = [];
    if site::cache_key(req, key) && gweb::cache_serve_key(req, ctx, res, key) { return false; }
    return true;
}

fn after(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    var key: u8[>..] = [];
    if site::cache_key(req, key) { gweb::cache_store_key(req, ctx, res, key, 0); }
}
