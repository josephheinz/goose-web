import std;
import net.http;
import web;

struct Props { ok: bool }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    ctx.title.append("About");
    return Props { ok: true };
}
