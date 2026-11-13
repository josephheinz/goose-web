// Part of gweb. Import with `import gweb.forms.form;`.

namespace gweb;

import std;
import net;
import net.http;
import gweb;

// Appends the URL-decoded field of a urlencoded form body to out; false when absent.
fn form(req: const http::Request&, name: const u8[:], out: u8[>..]&) -> bool {
    each_split(req.body, '&') { pair =>
        let key, value, has = split_once(pair, '=');
        if key == name { http::url_decode(out, value); return true; }
    };
    return false;
}

fn form_int(req: const http::Request&, name: const u8[:]) -> i64, bool {
    var v: u8[>..] = [];
    if !form(req, name, v) { return 0, false; }
    return parse_int(trim(v));
}

// The GW-Fragment header; "" for a whole page.
fn fragment(req: const http::Request&) -> const u8[:] {
    let v, has = http::header(req, "gw-fragment");
    return if has { trim(v) } else { "" };
}

// 1 for names[0], 2 for names[1]...; 0 for the whole page (no header, or an unknown name).
fn _fragment_index(req: const http::Request&, names: const u8[:][:]) -> i64 {
    let want = fragment(req);
    if want.len == 0 { return 0; }
    for n, i in names { if n == want { return i + 1; } }
    return 0;
}

// Adds Cache-Control: no-store unless the response already has it.
fn no_store(res: http::Response&) {
    if find(res.headers, "Cache-Control: no-store\r\n") < 0 { http::set_header(res, "Cache-Control", "no-store"); }
}

// Echoes the name in GW-Fragment, forbids caching, and keeps gweb dev's script out.
fn _fragment_reply(req: const http::Request&, ctx: Ctx&, res: http::Response&) {
    ctx.fragment = true;
    http::set_header(res, "GW-Fragment", fragment(req));
    no_store(res);
}
