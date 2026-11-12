import std;
import net.http;
import web;
import web.form;
import state;

struct Props { reply: state::Reply, ok: bool, error: u8[..100], draft: u8[..200] }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    ctx.title.append("Fragments");
    let r, ok = state::ask(ctx, state::Msg.List);
    return Props { reply: r, ok: ok, error: "", draft: "" };
}

fn POST(req: const http::Request&, ctx: web::Ctx&) -> Props {
    var error: u8[..100] = "";
    var draft: u8[..200] = "";
    var title: u8[>..] = [];
    var add: u8[>..] = [];
    if web::form(req, "add", add) && web::form(req, "title", title) {
        let t = trim(title);
        if t.len == 0 || t.len > 200 { error.append("A todo needs a title of 1 to 200 bytes."); draft.append(t[..min(t.len, 200)]); }
        else { var tt: u8[..200] = ""; tt.append(t); state::ask(ctx, state::Msg.Add { title: tt }); }
    }
    let id, has = web::form_int(req, "done");
    if has { state::ask(ctx, state::Msg.Update { id: id, title: "", has_title: false, done: true, has_done: true }); }
    let id2, has2 = web::form_int(req, "undo");
    if has2 { state::ask(ctx, state::Msg.Update { id: id2, title: "", has_title: false, done: false, has_done: true }); }
    let id3, has3 = web::form_int(req, "remove");
    if has3 { state::ask(ctx, state::Msg.Remove { id: id3 }); }
    var p = load(req, ctx);
    p.error = error;
    p.draft = draft;
    return p;
}
