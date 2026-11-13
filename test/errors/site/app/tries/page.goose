import std;
import net.http;
import gweb;
import gweb.site.errors;

struct Props { n: i64 = 0 }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    ctx.title.append("Tries");
    return Props { .. };
}

// No res parameter: gweb::fail ends the reply with the nearest error.html (D11).
fn POST(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    gweb::fail(ctx, 429, "Too many tries.");
    return Props { .. };
}
