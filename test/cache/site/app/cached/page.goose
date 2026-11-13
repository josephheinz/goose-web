import std;
import net.http;
import gweb;

const REVALIDATE = 2;

struct Props { n: i64 }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    let r, ok = state::ask(ctx, state::Msg.Next);
    return Props { n: r.n };
}

fn POST(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    return load(req, ctx);
}
