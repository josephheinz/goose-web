import std;
import net.http;
import web;

struct Props { n: i64 }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    ctx.title.append("Counter");
    let r, ok = state::ask(ctx, state::Msg.Get);
    return Props { n: if ok { r.n } else { -1 } };
}

fn POST(req: const http::Request&, ctx: web::Ctx&) -> Props {
    let r, ok = state::ask(ctx, state::Msg.Inc);
    return load(req, ctx);
}
