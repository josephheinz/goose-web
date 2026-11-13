import std;
import net.http;
import gweb;
import gweb.forms.valid;
import cms.store;
import cms.msg;
import views;

const SITEMAP = false;

struct Props { doc: cms::Doc, errs: gweb::FieldErrors, saved: bool }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    var p = Props { doc: cms::Doc { .. }, errs: gweb::no_errors(), saved: false };
    let id, ok = gweb::param_int(ctx, "id");
    if !ok || !cms::load_by_id(id, p.doc) { gweb::not_found(ctx); return p; }
    var s: u8[>..] = [];
    p.saved = gweb::query(req, "saved", s);
    ctx.title.append("Edit ");
    ctx.title.append(p.doc.path);
    return p;
}

// Both forms are parsed through the generated registry: names from the stored node, rules from the views' Props.
fn POST(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    var p = load(req, ctx);
    if p.doc.id == 0 { return p; }
    var tj: u8[>..] = [];
    var wj: u8[>..] = [];
    views::types_parse(req, p.doc.type_name, "t.", tj, p.errs);
    let has_text = cms::text_props(p.doc).len > 0;
    if has_text { views::widgets_parse(req, "Text", "w.", wj, p.errs); }
    if gweb::has_errors(p.errs) {
        cms::show_typed(p.doc, tj, wj);
        gweb::unprocessable(ctx);
        return p;
    }
    let r, ok = state::ask(ctx, state::Msg.Cms { m: cms::Msg.Save { id: p.doc.id, props: copy(tj), widget: copy(wj) } });
    if !ok || !r.cms.ok { gweb::fail(ctx, 500, "The page was not saved."); return p; }
    gweb::epoch_bump();
    var to: u8[>..] = [];
    format(to, "/admin/nodes/", p.doc.id, "?saved=1");
    gweb::redirect(ctx, to, 303);
    return p;
}
