import std;
import net.http;
import gweb;
import gweb.http.push;

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    gweb::websocket(req, ctx, res, "chat", "good.example");
}
