import std;
import net.http;
import web;

// The plaintext benchmark target.
fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    http::text(res, http::Status.Ok, "Hello, World!");
}
