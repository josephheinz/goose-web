import std;
import net.http;
import web;

// Marks the browser on its first visit to /cookies: a session cookie that
// scripts cannot read (the defaults).
fn before(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) -> bool {
    let v, has = http::cookie(req, "shop_seen");
    if !has { web::set_cookie(ctx, "shop_seen", "1"); }
    return true;
}
