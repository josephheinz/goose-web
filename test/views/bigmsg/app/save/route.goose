import std;
import net.http;
import gweb;

const CSRF = false;

fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    let r, ok = state::ask(ctx, state::Msg.Save { doc: req.body });
    var s: u8[>..] = [];
    format(s, "ok=", ok, " n=", r.n, " total=", r.total, " saves=", r.saves);
    http::text(res, http::Status.Ok, s);
}
