import std;
import net.http;
import web;
import Name;
struct Props { n: i64, html: u8[..32], items: i64[..4], s: Name::State }
fn badge(out: u8[>..]&, n: i64) { out.append("#"); }
fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    var p = Props { n: 2, html: "<u>x</u>", items: [], s: Name::State { .. } };
    p.items.push(7);
    return p;
}
