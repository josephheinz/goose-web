import std;
import net.http;
import gweb;
import cms.store;

const SITEMAP = false;

struct Props { rows: cms::Row[..32], count: i64, channels: cms::Channel[..4], err: u8[..200] }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    ctx.title.append("Admin");
    var p = Props { rows: [], count: 0, channels: [], err: "" };
    cms::list_nodes("", p.rows);
    p.count = p.rows.len;
    for host in ["a.test", "b.test"] {
        var ch = cms::Channel { .. };
        if cms::channel_by_host(host, ch) { p.channels.push(ch); }
    }
    var e: u8[>..] = [];
    if gweb::query(req, "error", e) { p.err.append(e[..min(e.len, 200)]); }
    return p;
}
