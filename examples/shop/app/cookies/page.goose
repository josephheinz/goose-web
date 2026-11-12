import std;
import net.http;
import web;

struct Props { theme: const u8[:], visits: i64, returning: bool }

let YEAR = 31536000;

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    ctx.title.append("Cookies");
    let seen, returning = http::cookie(req, "shop_seen");
    let n, counted = web::cookie_int(req, "visits");
    let visits = if counted && n >= 0 && n < 1000000 { n + 1 } else { 1 };
    var text: u8[..24] = "";
    format(text, visits);
    web::set_cookie(ctx, "visits", text, web::CookieOptions { max_age: YEAR, http_only: false, .. });
    let theme = if web::cookie_or(req, "theme", "light") == "dark" { "dark" } else { "light" };
    return Props { theme: theme, visits: visits, returning: returning };
}
