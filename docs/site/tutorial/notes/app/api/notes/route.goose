import std;
import net.http;
import web;
import json;

fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    let reply, ok = state::ask(ctx, state::Msg { add: false, text: "" });
    if !ok { http::json_error(res, http::Status.ServiceUnavailable, "state unavailable"); return; }
    web::json(res, http::Status.Ok);
    res.body.push('[');
    for n, i in reply.notes {
        if i > 0 { res.body.push(','); }
        res.body.push('{');
        json::format_key(res.body, "id");
        format(res.body, n.id, ",");
        json::format_key(res.body, "text");
        json::format_string(res.body, n.text);
        res.body.push('}');
    }
    res.body.push(']');
}
