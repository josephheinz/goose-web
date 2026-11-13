import std;
import net.http;
import gweb;

// Indexes past the end of the array: the worker aborts; the reply is JSON.
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    let a: i64[3] = [1, 2, 3];
    let k = ctx.params.n + 7;
    http::text(res, http::Status.Ok, "unreachable");
    format(res.body, a[k]);
}
