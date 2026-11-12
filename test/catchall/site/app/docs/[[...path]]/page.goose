import std;
import net.http;
import web;

struct Props { n: i64 }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    return Props { n: 1 };
}
