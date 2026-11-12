import std;
import net.http;
import web;
import Brace;
import lib.util;
struct Props { b: Brace::State, url: const u8[:] }
fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    var p = Props { b: Brace::State { .. }, url: "/x.js?a=1&b=2" };
    p.b.n = 5; p.b.t.append("hi <b>");
    return p;
}
