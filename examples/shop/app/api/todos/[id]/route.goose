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

fn answer(res: http::Response&, r: const state::Reply&, sent: bool) {
    if !sent { http::json_error(res, http::Status.ServiceUnavailable, "state unavailable"); return; }
    if !r.ok { http::json_error(res, http::Status.NotFound, "todo not found"); return; }
    web::json(res, http::Status.Ok);
    var any = false;
    for t in r.todos { write_todo(res.body, t); any = true; }
    if !any { res.body.append("{\"deleted\":true}"); }
}

fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    let id, ok = web::param_int(ctx, "id");
    if !ok { http::json_error(res, http::Status.BadRequest, "id must be an integer"); return; }
    let r, sent = state::ask(ctx, state::Msg.Get { id: id });
    answer(res, r, sent);
}

fn PUT(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    let id, ok = web::param_int(ctx, "id");
    if !ok { http::json_error(res, http::Status.BadRequest, "id must be an integer"); return; }
    let input, valid = shop::parse_todo(req.body);
    if !valid { http::json_error(res, http::Status.BadRequest, "send {\"title\": \"...\", \"done\": true}"); return; }
    let r, sent = state::ask(ctx, state::Msg.Update { id: id, title: input.title, has_title: input.has_title,
                                                      done: input.done, has_done: input.has_done });
    answer(res, r, sent);
}

fn DELETE(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    let id, ok = web::param_int(ctx, "id");
    if !ok { http::json_error(res, http::Status.BadRequest, "id must be an integer"); return; }
    let r, sent = state::ask(ctx, state::Msg.Remove { id: id });
    answer(res, r, sent);
}
