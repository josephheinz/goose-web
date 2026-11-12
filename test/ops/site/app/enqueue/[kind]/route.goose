import std;
import net.http;
import web;

fn POST(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    let kind = web::param(ctx, "kind");
    var ok = false;
    if kind == "bump" { ok = jobs::enqueue(ctx, jobs::Job.Bump); }
    else if kind == "fail" { ok = jobs::enqueue(ctx, jobs::Job.Fail); }
    else if kind == "boom" { ok = jobs::enqueue(ctx, jobs::Job.Boom); }
    else { http::text(res, http::Status.NotFound, "unknown job\n"); return; }
    if ok { http::text(res, http::Status.Accepted, "queued\n"); }
    else { http::text(res, http::Status.ServiceUnavailable, "job queue refused\n"); }
}
