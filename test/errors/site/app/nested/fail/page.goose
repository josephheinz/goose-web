import std;
import net.http;
import web;
import web.errors;

struct Props { n: i64 }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    web::fail(ctx, 409, "Conflict here.");
    return Props { n: 0 };
}
