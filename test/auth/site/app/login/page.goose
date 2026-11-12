import std;
import net.http;
import web;

struct Props { next: u8[..512], err: bool }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    ctx.title.append("Log in");
    var p = Props { next: "", err: false };
    var n: u8[>..] = [];
    if web::query(req, "next", n) { p.next.append(n[..min(n.len, 512)]); }
    var e: u8[>..] = [];
    p.err = web::query(req, "error", e);
    return p;
}
