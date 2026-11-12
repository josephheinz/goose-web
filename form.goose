// Part of goose-web. Import with `import web.form;`.

namespace web;

import std;
import net from "../goose-net";
import net.http;
import web;

// Forms and fragments (DESIGN-ADDENDUM-4).

// A field of a form posted as application/x-www-form-urlencoded, URL-decoded
// and appended to out. False when absent.
fn form(req: const http::Request&, name: const u8[:], out: u8[>..]&) -> bool {
    each_split(req.body, '&') { pair =>
        let key, value, has = split_once(pair, '=');
        if key == name { http::url_decode(out, value); return true; }
    };
    return false;
}

// A form field as an integer.
fn form_int(req: const http::Request&, name: const u8[:]) -> i64, bool {
    var v: u8[>..] = [];
    if !form(req, name, v) { return 0, false; }
    return parse_int(trim(v));
}

// The fragment a request asks for (its GW-Fragment header); "" for a whole page.
fn fragment(req: const http::Request&) -> const u8[:] {
    let v, has = http::header(req, "gw-fragment");
    return if has { trim(v) } else { "" };
}

// Which of a page's fragments the request asks for: 1 for names[0], 2 for
// names[1]...; 0 for the whole page (no header, or a name the page lacks).
fn fragment_index(req: const http::Request&, names: const u8[:][:]) -> i64 {
    let want = fragment(req);
    if want.len == 0 { return 0; }
    for n, i in names { if n == want { return i + 1; } }
    return 0;
}

// Marks the reply as a fragment: echoes the name in GW-Fragment, forbids
// caching, and keeps gweb dev's script out of it.
fn fragment_reply(req: const http::Request&, ctx: Ctx&, res: http::Response&) {
    ctx.fragment = true;
    http::set_header(res, "GW-Fragment", fragment(req));
    http::set_header(res, "Cache-Control", "no-store");
}

// A browser says this request comes from another site (Sec-Fetch-Site:
// cross-site). Generated page code refuses such a POST.
fn cross_site(req: const http::Request&) -> bool {
    let v, has = http::header(req, "sec-fetch-site");
    return has && trim(v) == "cross-site";
}
