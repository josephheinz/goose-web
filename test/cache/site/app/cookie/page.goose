import std;
import net.http;
import gweb;

const REVALIDATE = 2;

struct Props { n: i64 }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    gweb::set_cookie(ctx, "seen", "1");
    let r, ok = state::ask(ctx, state::Msg.Next);
    return Props { n: r.n };
}
