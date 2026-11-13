// A foreign field type for views (README: Views, Foreign types): a picked media file.
namespace cms;

import std;
import net.http;
import json;
import gweb;
import gweb.site.views;
import gweb.forms.valid;

struct Media { key: u8[..32] = "", name: u8[..120] = "" }

fn gw_read(r: json::Reader&, v: Media&, warn: i64&) {
    if json::peek(r) != '{' { json::skip(r); warn += 1; return; }
    json::each_member(r) { k =>
        if k == "key" { gweb::_jr_text(r, v.key, warn); }
        else if k == "name" { gweb::_jr_text(r, v.name, warn); }
        else { json::skip(r); }
    };
}

fn gw_write(out: u8[>..]&, v: const Media&) {
    out.push('{');
    json::format_key(out, "key"); json::format_string(out, v.key);
    out.push(',');
    json::format_key(out, "name"); json::format_string(out, v.name);
    out.push('}');
}

// Without JavaScript the picker is two text inputs; editor.js would turn it into a button.
fn gw_field(out: u8[>..]&, name: const u8[:], v: const Media&, label: const u8[:], help: const u8[:], editor: const u8[:], errs: const gweb::FieldErrors&) {
    out.append("<p class=\"gw-field media-picker\"><label for=\"");
    gweb::escape(out, name);
    out.append(".key\">");
    gweb::escape(out, label);
    out.append("</label> <input id=\"");
    gweb::escape(out, name);
    out.append(".key\" name=\"");
    gweb::escape(out, name);
    out.append(".key\" value=\"");
    gweb::escape(out, v.key);
    out.append("\"> <input name=\"");
    gweb::escape(out, name);
    out.append(".name\" value=\"");
    gweb::escape(out, v.name);
    out.append("\"></p>\n");
}

fn gw_parse(req: const http::Request&, name: const u8[:], v: Media&, errs: gweb::FieldErrors&) -> bool {
    var n: u8[>..] = [];
    format(n, name, ".key");
    gweb::form_text(req, n, v.key, errs, false);
    n.clear();
    format(n, name, ".name");
    gweb::form_text(req, n, v.name, errs, false);
    return true;
}
