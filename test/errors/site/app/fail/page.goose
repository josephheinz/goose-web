import std;
import net.http;
import gweb;
import gweb.site.errors;

struct Props { n: i64 }

// A deliberate error: finish answers it with the nearest error.html.
fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    gweb::fail(ctx, 503, "Down for maintenance.");
    return Props { n: 0 };
}
