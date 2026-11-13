import std;
import net.http;
import gweb;

struct Props { n: i64 }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    let id, ok = gweb::param_int(ctx, "id");
    ctx.title.append("item");
    return Props { n: id };
}
