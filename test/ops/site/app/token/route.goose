import std;
import net.http;
import gweb;

// A per-process random token: a handoff shows as a new value.
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    let r, ok = state::ask(ctx, state::Msg.Get);
    if !ok { http::text(res, http::Status.ServiceUnavailable, "state unavailable\n"); return; }
    var out: u8[>..] = [];
    format(out, r.token, "\n");
    http::text(res, http::Status.Ok, out);
}
