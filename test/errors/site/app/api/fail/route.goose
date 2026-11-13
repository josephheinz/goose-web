import std;
import net.http;
import gweb;
import gweb.site.errors;

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    gweb::fail(ctx, 429, "Slow down.");
}
