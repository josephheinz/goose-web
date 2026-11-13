import std;
import net.http;
import gweb;
import gweb.site.errors;

struct Props { n: i64 = 0 }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    ctx.title.append("Limit");
    return Props { .. };
}

// Takes res, so gweb passes it. The handler writes the whole reply and calls gweb::done (D14).
fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) -> Props {
    res.status = http::status_from_code(429);
    http::set_header(res, "Retry-After", "30");
    res.content_type.clear();
    res.content_type.append("text/plain; charset=utf-8");
    res.body.clear();
    res.body.append("slow down");
    gweb::done(ctx);
    return Props { .. };
}
