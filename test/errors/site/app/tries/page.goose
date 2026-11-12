import std;
import net.http;
import web;
import web.errors;

struct Props { n: i64 = 0 }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    ctx.title.append("Tries");
    return Props { .. };
}

// No res parameter: web::fail ends the reply with the nearest error.html (D11).
fn POST(req: const http::Request&, ctx: web::Ctx&) -> Props {
    web::fail(ctx, 429, "Too many tries.");
    return Props { .. };
}
