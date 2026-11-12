import std;
import net.http;
import web;

fn POST(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    http::text(res, http::Status.Ok, "saved\n");
}
