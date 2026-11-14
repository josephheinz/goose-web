import std;
import gweb;

enum Job { Plain, Local }

fn run(job: const Job&, ctx: gweb::Ctx&) -> bool {
    match job {
        Plain => { let r, ok = state::ask(ctx, state::Msg.Plain); return ok; },
        Local => { let r, ok = state::ask(ctx, state::Msg.Local); return ok; },
    }
}

fn schedule(s: gweb::Schedules&) {
    jobs::every(s, "plain", 200, Job.Plain);
    jobs::every_local(s, "local", 200, Job.Local);
}
