import std;
import net.http;
import gweb;
import gweb.http.push;

const CSRF = false;

fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    var sse: u8[>..] = [];
    format(sse, "data: ", req.body, "\n\n");
    gweb::publish(ctx, "news", sse);
    gweb::publish(ctx, "chat", req.body);
    http::text(res, http::Status.Ok, "sent\n");
}
