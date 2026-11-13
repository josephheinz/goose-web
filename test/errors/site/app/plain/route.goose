import std;
import net.http;
import gweb;

// The plaintext benchmark target.
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    http::text(res, http::Status.Ok, "Hello, World!");
}
