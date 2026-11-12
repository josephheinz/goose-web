import std;
import net.http;
import web;

// POST /cookies/reset: deletes the three cookies.
fn POST(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    web::clear_cookie(ctx, "theme");
    web::clear_cookie(ctx, "visits");
    web::clear_cookie(ctx, "shop_seen");
    web::redirect(ctx, "/cookies", 303);
}
