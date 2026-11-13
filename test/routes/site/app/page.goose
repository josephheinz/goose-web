import std;
import net.http;
import gweb;

struct Props { n: i64 }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    ctx.title.append("Counter");
    let r, ok = state::ask(ctx, state::Msg.Get);
    return Props { n: if ok { r.n } else { -1 } };
}

fn POST(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    let r, ok = state::ask(ctx, state::Msg.Inc);
    return load(req, ctx);
}
