import std;
import net.http;
import gweb;
import shop.orders;

const SITEMAP = false;

struct Props { count: i64 }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    ctx.title.append("Orders");
    return Props { count: shop::order_count() };
}
