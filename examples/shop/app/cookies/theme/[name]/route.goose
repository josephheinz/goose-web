import std;
import net.http;
import web;

// POST /cookies/theme/dark or /light: stores the choice for a year, then
// goes back to the page.
fn POST(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    let name = web::param(ctx, "name");
    if name != "dark" && name != "light" { http::json_error(res, http::Status.BadRequest, "theme is dark or light"); return; }
    web::set_cookie(ctx, "theme", name, web::CookieOptions { max_age: 31536000, http_only: false, .. });
    web::redirect(ctx, "/cookies", 303);
}
