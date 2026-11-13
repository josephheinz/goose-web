// A foreign field type: views call link::gw_read, gw_write, gw_field and gw_parse for a `link::Link` field.
namespace link;

import std;
import net.http;
import json;
import gweb;
import gweb.site.views;
import gweb.forms.valid;
import gweb.site.template;

struct Link { href: u8[..100] = "", text: u8[..40] = "" }

fn gw_read(r: json::Reader&, v: Link&, warn: i64&) {
    if json::peek(r) != '{' { json::skip(r); warn += 1; return; }
    json::each_member(r) { key =>
        if key == "href" { gweb::jr_text(r, v.href, warn); }
        else if key == "text" { gweb::jr_text(r, v.text, warn); }
        else { json::skip(r); }
    };
}

fn gw_write(out: u8[>..]&, v: const Link&) {
    out.push('{');
    json::format_key(out, "href"); json::format_string(out, v.href);
    out.push(',');
    json::format_key(out, "text"); json::format_string(out, v.text);
    out.push('}');
}

fn gw_field(out: u8[>..]&, name: const u8[:], v: const Link&, label: const u8[:], help: const u8[:], editor: const u8[:], errs: const gweb::FieldErrors&) {
    out.append("<div class=\"link-picker\" data-name=\"");
    gweb::escape(out, name);
    out.append("\">");
    gweb::escape(out, label);
    out.append(": ");
    gweb::escape(out, v.href);
    out.append("</div>\n");
}

fn gw_parse(req: const http::Request&, name: const u8[:], v: Link&, errs: gweb::FieldErrors&) -> bool {
    var n: u8[>..] = [];
    format(n, name, ".href");
    gweb::form_text(req, n, v.href, errs, false);
    n.clear();
    format(n, name, ".text");
    gweb::form_text(req, n, v.text, errs, false);
    return true;
}
