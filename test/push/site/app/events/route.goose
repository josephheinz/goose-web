import std;
import net.http;
import gweb;
import gweb.http.push;

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    res.content_type.clear();
    res.content_type.append("text/event-stream");
    gweb::subscribe(req, ctx, res, "news", ": ping\n\n");
}
