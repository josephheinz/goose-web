import std;
import net.http;
import web;

struct Props { n: i64 }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    let id, ok = web::param_int(ctx, "id");
    ctx.title.append("item");
    return Props { n: id };
}
