import std;
import net.http;
import web;
import admin.users;

struct Props { count: i64 }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    return Props { count: admin::user_count() };
}
