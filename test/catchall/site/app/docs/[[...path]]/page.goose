import std;
import net.http;
import gweb;

struct Props { n: i64 }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    return Props { n: 1 };
}
