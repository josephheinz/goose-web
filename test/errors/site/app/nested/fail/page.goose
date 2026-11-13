import std;
import net.http;
import gweb;
import gweb.site.errors;

struct Props { n: i64 }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    gweb::fail(ctx, 409, "Conflict here.");
    return Props { n: 0 };
}
