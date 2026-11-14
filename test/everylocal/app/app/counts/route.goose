import std;
import net.http;
import gweb;

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    let r, ok = state::ask(ctx, state::Msg.Get);
    gweb::json(res, http::Status.Ok);
    format(res.body, "{\"plain\":", r.plain, ",\"local\":", r.local, "}");
}
