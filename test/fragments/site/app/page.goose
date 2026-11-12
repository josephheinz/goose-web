import std;
import net.http;
import web;
import web.form;

struct Props { msg: u8[..300], n: i64 }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    ctx.title.append("Frag");
    return Props { msg: "", n: 7 };
}

// A title field is shown back; a go field redirects with 303.
fn POST(req: const http::Request&, ctx: web::Ctx&) -> Props {
    var p = load(req, ctx);
    var go: u8[>..] = [];
    if web::form(req, "go", go) { web::redirect(ctx, "/other", 303); return p; }
    var t: u8[>..] = [];
    web::form(req, "title", t);
    p.msg.append(t[..min(t.len, 300)]);
    return p;
}
