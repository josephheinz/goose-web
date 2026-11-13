import std;
import net.http;
import gweb;
import gweb.forms.form;
import cms.store;
import cms.msg;
import views;

// A new page: its path must be a plain slug that no route, public file or mount uses (gweb::reserved_prefixes).
fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    var path: u8[>..] = [];
    var chan: u8[>..] = [];
    gweb::form(req, "path", path);
    gweb::form(req, "channel", chan);
    let ch, cok = parse_int(chan);
    if !cok || !cms::slug_ok(path) {
        gweb::redirect(ctx, "/admin?error=That+path+is+reserved+or+not+a+plain+slug", 303);
        return;
    }
    var props: u8[>..] = [];
    var text: u8[>..] = [];
    views::types_defaults("Article", props);
    views::widgets_defaults("Text", text);
    let r, ok = state::ask(ctx, state::Msg.Cms { m: cms::Msg.Create { channel: ch, path: copy(path), props: copy(props), widget: copy(text) } });
    if !ok || !r.cms.ok {
        gweb::redirect(ctx, "/admin?error=Could+not+create+that+page", 303);
        return;
    }
    gweb::epoch_bump();
    var to: u8[>..] = [];
    format(to, "/admin/nodes/", r.cms.id);
    gweb::redirect(ctx, to, 303);
}
