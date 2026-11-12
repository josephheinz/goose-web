// A hand-written dispatcher on the goose-web runtime (no gweb), for testing.
// It has the shape gweb generates: dispatch, then finish.
//   goose build test/manual.goose && test/manual --port 3101 --workers 4 --log
import web from "..";
import net from "../../goose-net";
import net.http;
import web.template;
import web.static;
import std;

let CSS = "body { color: red }\n";

fn static_file(i: i64) -> const u8[:] { if i == 0 { CSS } else { "" } }

fn finish(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    match ctx.outcome {
        NotFound => { ctx.title.clear(); web::plain_not_found(res); },
        Redirect => web::apply_redirect(ctx, res),
        Continue => {},
    }
}

fn route(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) -> i64 {
    var seg: const u8[:][16] = [""; 16];
    var starts: i64[16] = [0; 16];
    var ends: i64[16] = [0; 16];
    let n = web::split(req.path, seg, starts, ends);
    if n == 0 {
        web::html(res, http::Status.Ok);
        res.body.append("<h1>home</h1><p>");
        web::put(res.body, "<b>&'\"");
        res.body.append("</p>");
        return -1;
    }
    if n == 2 && seg[0] == "items" {
        if !web::set_param(ctx, "id", seg[1]) { web::not_found(ctx); return -1; }
        let id, ok = web::param_int(ctx, "id");
        if !ok { http::json_error(res, http::Status.BadRequest, "id must be an integer"); return -1; }
        if id == 0 { web::not_found(ctx); return -1; }
        res.body.append("discarded");
        web::json(res, http::Status.Ok);
        res.body.clear();
        format(res.body, "{\"id\":", id, ",\"param\":\"", web::param(ctx, "id"), "\",\"worker\":", ctx.worker, "}");
        return -1;
    }
    if n == 1 && seg[0] == "old" { web::redirect(ctx, "/items/7", 301); return -1; }
    if n == 1 && seg[0] == "site.css" { return web::send_static(req, res, 0, "text/css", "\"abc123\""); }
    web::not_found(ctx);
    return -1;
}

fn dispatch(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) -> i64 {
    let i = route(req, ctx, res);
    finish(req, ctx, res);
    return i;
}

thread_fn worker(slot: i64, server: net::Socket, cfg: web::Config) {
    web::run_worker(slot, server, -1, cfg, dispatch, static_file);
}

fn main() {
    let cfg = web::config_from_args();
    let server = net::listen(cfg.port, cfg.host);
    guard server.ok() else { print(net::last_error()); exit(1); }
    print("listening on ", cfg.port, " with ", cfg.workers, " workers");
    var ids: i64[>..] = [];
    for i in cfg.workers { ids.push(thread_spawn(worker, i, server, cfg)); }
    for id in ids { thread_wait(id); }
}
