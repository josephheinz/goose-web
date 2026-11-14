import std;
import net.http;
import gweb;

struct Props { q: u8[..64] }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    var p = Props { q: "" };
    var q: u8[>..] = [];
    gweb::query(req, "q", q);
    p.q.append(q[..min(q.len, 64)]);
    return p;
}
