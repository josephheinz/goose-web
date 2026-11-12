import std;
import web;

enum Job { Bump, Tick, Fail, Boom }

fn run(job: const Job&, ctx: web::Ctx&) -> bool {
    match job {
        Bump => { let r, ok = state::ask(ctx, state::Msg.Add { n: 1 }); return ok; },
        Tick => { let r, ok = state::ask(ctx, state::Msg.Tick); return ok; },
        Fail => { return false; },
        Boom => { abort("boom"); },
    }
}

fn schedule(s: web::Schedules&) {
    jobs::every(s, "tick", 1000, Job.Tick);
}
