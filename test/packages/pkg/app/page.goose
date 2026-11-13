import std;
import net.http;
import gweb;
import admin.users;

struct Props { count: i64 }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    return Props { count: admin::user_count() };
}
