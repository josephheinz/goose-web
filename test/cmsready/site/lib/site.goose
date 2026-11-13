// The glue between the stored documents and the generated views registry.
namespace site;

import std;
import net.http;
import gweb;
import cms.store;
import views;

let BODY = -2;

// The Host header, lower case, without the port.
fn host_of(req: const http::Request&, out: u8[>..]&) {
    let h, has = http::header(req, "host");
    if !has { return; }
    var n = h.len;
    let colon = rfind(h, ":");
    if colon >= 0 { n = colon; }
    while n > 0 && h[n - 1] == '.' { n -= 1; }
    for c in h[..n] { out.push(if c >= 'A' && c <= 'Z' { c + 32 } else { c }); }
}

// host, a newline, then the target; false for a request with a query string (not cached).
fn cache_key(req: const http::Request&, key: u8[>..]&) -> bool {
    if find(req.target, "?") >= 0 { return false; }
    host_of(req, key);
    key.push('\n');
    key.append(req.target);
    return key.len <= 1280;
}

// Runs for every @slot("x"): the layout's body (at = BODY), a page type's area (at = -1) and a section's zone (at = its index).
recursive fn fill(out: u8[>..]&, req: const http::Request&, ctx: const gweb::Ctx&, doc: const cms::Doc&, at: i64, name: const u8[:]) {
    if at == BODY {
        if !views::types_render(out, req, ctx, doc.type_name, doc.props, doc, -1, fill) { out.append("<!--no such type-->"); }
        return;
    }
    let parent = if at < 0 { 0 } else { doc.widgets[at].id };
    for i in doc.widgets.len {
        let w = doc.widgets[i];
        if w.parent != parent || w.zone != name { continue; }
        var ok = false;
        if w.section { ok = views::sections_render(out, req, ctx, w.view, w.props, doc, i, fill); }
        else { ok = views::widgets_render(out, req, ctx, w.view, w.props, doc, i, fill); }
        if !ok { out.append("<!--no such view-->"); }
    }
}

fn page(out: u8[>..]&, req: const http::Request&, ctx: const gweb::Ctx&, doc: const cms::Doc&) {
    if !views::layouts_render(out, req, ctx, doc.channel.layout, "{}", doc, BODY, fill) { out.append("<!--no layout-->"); }
}
