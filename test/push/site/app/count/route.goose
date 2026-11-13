import std;
import net.http;
import gweb;
import gweb.http.push;

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    var out: u8[>..] = [];
    format(out, "news=", gweb::subscribers(ctx, "news"), " chat=", gweb::subscribers(ctx, "chat"), "\n");
    http::text(res, http::Status.Ok, out);
}
