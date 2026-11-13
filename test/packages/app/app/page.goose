import std;
import net.http;
import gweb;
import Badge;

struct Props { b: Badge::State }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    var p = Props { b: Badge::State { .. } };
    p.b.n = 7;
    return p;
}
