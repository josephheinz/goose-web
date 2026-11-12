import std;
import net.http;
import web;

struct Props { v: i64 }

// Indexes past the end of the array: the worker aborts.
fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    let a: i64[3] = [10, 20, 30];
    let k = ctx.params.n + 5;
    return Props { v: a[k] };
}
