import std;
import net.http;
import gweb;

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    var s: u8[>..] = [];
    format(s, "blog-id:", gweb::param(ctx, "id"));
    http::text(res, http::Status.Ok, s);
}
