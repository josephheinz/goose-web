import std;
import net.http;
import web;
import json;
import state;
import lib.shop;

fn write_todo(out: u8[>..]&, t: const state::Todo&) {
    out.push('{');
    json::format_key(out, "id"); json::format_int(out, t.id); out.push(',');
    json::format_key(out, "title"); json::format_string(out, t.title); out.push(',');
    json::format_key(out, "done"); json::format_bool(out, t.done);
    out.push('}');
}

fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    let r, ok = state::ask(ctx, state::Msg.List);
    if !ok { http::json_error(res, http::Status.ServiceUnavailable, "state unavailable"); return; }
    web::json(res, http::Status.Ok);
    res.body.push('[');
    for t, i in r.todos {
        if i > 0 { res.body.push(','); }
        write_todo(res.body, t);
    }
    res.body.push(']');
}

fn POST(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    let input, ok = shop::parse_todo(req.body);
    if !ok || !input.has_title { http::json_error(res, http::Status.BadRequest, "send {\"title\": \"...\"}"); return; }
    let r, sent = state::ask(ctx, state::Msg.Add { title: input.title });
    if !sent { http::json_error(res, http::Status.ServiceUnavailable, "state unavailable"); return; }
    web::json(res, http::Status.Created);
    for t in r.todos { write_todo(res.body, t); }
}
