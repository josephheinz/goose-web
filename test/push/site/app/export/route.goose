import std;
import net.http;
import gweb;
import gweb.http.stream;

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    res.content_type.clear();
    res.content_type.append("text/plain; charset=utf-8");
    var s = gweb::stream_begin(req, ctx, res);
    gweb::stream_write(s, "one\n");
    gweb::stream_write(s, "two\n");
    gweb::stream_write(s, "three\n");
    gweb::stream_end(ctx, s);
}
