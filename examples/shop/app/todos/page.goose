import std;
import net.http;
import web;
import state;

struct Props { reply: state::Reply, ok: bool }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    ctx.title.append("Todos");
    let r, ok = state::ask(ctx, state::Msg.List);
    return Props { reply: r, ok: ok };
}
