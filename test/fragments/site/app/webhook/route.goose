import std;
import net.http;
import web;

const CSRF = false;

fn POST(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    http::text(res, http::Status.Ok, "hook\n");
}
