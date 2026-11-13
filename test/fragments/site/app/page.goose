import std;
import net.http;
import gweb;
import gweb.forms.form;

struct Props { msg: u8[..300], n: i64 }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    ctx.title.append("Frag");
    return Props { msg: "", n: 7 };
}

// A title field is shown back; a go field redirects with 303.
fn POST(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    var p = load(req, ctx);
    var go: u8[>..] = [];
    if gweb::form(req, "go", go) { gweb::redirect(ctx, "/other", 303); return p; }
    var t: u8[>..] = [];
    gweb::form(req, "title", t);
    p.msg.append(t[..min(t.len, 300)]);
    return p;
}
