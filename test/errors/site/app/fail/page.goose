import std;
import net.http;
import web;
import web.errors;

struct Props { n: i64 }

// A deliberate error: finish answers it with the nearest error.html.
fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    web::fail(ctx, 503, "Down for maintenance.");
    return Props { n: 0 };
}
