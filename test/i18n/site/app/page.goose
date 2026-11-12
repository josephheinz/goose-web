import std;
import net.http;
import web;

struct Props { n: i64 }

// ?n= is the plural count and the stock; 1 without it.
fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    var n = 1;
    let v, has = http::query_param(req, "n");
    if has {
        let x, ok = parse_int(v);
        if ok { n = x; }
    }
    return Props { n: n };
}
