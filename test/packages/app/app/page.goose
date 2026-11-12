import std;
import net.http;
import web;
import Badge;

struct Props { b: Badge::State }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    var p = Props { b: Badge::State { .. } };
    p.b.n = 7;
    return p;
}
