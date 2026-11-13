import std;
import os;
import net.http;
import gweb;
import cms.store;
import lib.site;

const SITEMAP = false;

// The stamp is when this page was rendered: two replies with the same stamp came from the cache.
struct Props { doc: cms::Doc, stamp: i64 }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    var p = Props { doc: cms::Doc { .. }, stamp: time_ns() };
    var host: u8[>..] = [];
    site::host_of(req, host);
    var path: u8[>..] = [];
    path.push('/');
    gweb::path_decode(path, gweb::param(ctx, "path"));
    var ch = cms::Channel { .. };
    if !cms::channel_by_host(host, ch) || !cms::load_doc(ch, path, p.doc) { gweb::not_found(ctx); return p; }
    ctx.title.append(ch.name);
    return p;
}
