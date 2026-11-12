import net.http;
import web;

fn after(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    http::set_header(res, "X-Outer", "1");
}
