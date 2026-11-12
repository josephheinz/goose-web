import std;
import net.http;
import web;
import web.form;
import CharCount;

struct Props { reply: state::Reply, counter: CharCount::State, error: u8[..100] }

// Sends one message to the owner. An unreachable owner gives an empty reply.
fn ask(ctx: web::Ctx&, msg: state::Msg) -> state::Reply {
    let reply, ok = state::ask(ctx, msg);
    if !ok { return state::Reply { .. }; }
    return reply;
}

fn page(ctx: web::Ctx&, reply: state::Reply) -> Props {
    ctx.title.append("Notes");
    return Props { reply: reply, counter: CharCount::State { text: "" }, error: "" };
}

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    return page(ctx, ask(ctx, state::Msg { add: false, text: "" }));
}

fn POST(req: const http::Request&, ctx: web::Ctx&) -> Props {
    var text: u8[>..] = [];
    web::form(req, "text", text);
    let t = trim(text);
    if t.len == 0 || t.len > 200 {
        var p = load(req, ctx);
        p.error.append("A note is 1 to 200 bytes.");
        return p;
    }
    var msg = state::Msg { add: true, text: "" };
    msg.text.append(t);
    return page(ctx, ask(ctx, msg));
}
