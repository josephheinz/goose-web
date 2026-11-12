import std;
import net.http;
import web;

fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    http::text(res, http::Status.Ok, "admin-users");
}
