// Part of gweb. Import with `import gweb.ops.jobs;`.
// The in-memory job queue and scheduler (src/jobs.c). `gweb` generates the typed wrappers and the runner threads
// on top of these: a job is opaque bytes here.

namespace gweb;

import std;
import net;
import net.http;
import gweb;
import ops.log;

extern fn c_jobs_init(runners: i32, cap: i64, attempts: i32) = "gweb_jobs_init";
extern fn c_jobs_push(bytes: const u8[:], delay_ms: i64) -> i32 = "gweb_jobs_push";
extern fn c_jobs_take(slot: i32, timeout_ms: i64, out: u8[>..]&, id: i64&, attempt: i64&, sched_name: u8[>..]&) -> i32 = "gweb_jobs_take";
extern fn c_jobs_done(slot: i32, ok: i32) = "gweb_jobs_done";
extern fn c_jobs_abandon(slot: i32) -> i32 = "gweb_jobs_abandon";
extern fn c_jobs_every(name: const u8[:], ms: i64, bytes: const u8[:]) -> i32 = "gweb_jobs_every";
extern fn c_jobs_cron(name: const u8[:], spec: const u8[:], bytes: const u8[:]) -> i32 = "gweb_jobs_cron";
extern fn c_jobs_stop() = "gweb_jobs_stop";
extern fn c_jobs_stat(which: i32) -> i64 = "gweb_jobs_stat";
extern fn c_cron_next(spec: const u8[:], after_unix: i64) -> i64 = "gweb_cron_next";

// What jobs::schedule registers into. bad counts the schedules that were refused (a duplicate or invalid name,
// a bad cron spec, or the queue already stopped); the generated main exits with status 1 when it is above 0.
// enabled is false with --no-schedule: schedules are checked, but none is registered.
struct Schedules { enabled: bool = true, n: i64 = 0, bad: i64 = 0 }

// Call once, before the runners start: the queue holds cfg.job_queue jobs, a job gets cfg.job_attempts attempts,
// and cfg.job_runners runners will take from it.
fn _jobs_init(cfg: const Config&) {
    c_jobs_init(cfg.job_runners as i32, cfg.job_queue, cfg.job_attempts as i32);
}

// The Schedules for jobs::schedule, honouring --no-schedule.
fn _new_schedules(cfg: const Config&) -> Schedules { Schedules { enabled: cfg.schedule } }

// Stops the scheduler and refuses new jobs; job_take returns at once from then on. Call when the server starts to stop.
fn _jobs_stop() { c_jobs_stop(); }

// Jobs waiting, for the shutdown message.
fn _jobs_queued() -> i64 { c_jobs_stat(0) }

// Queues a job. False when the queue is full or the server is stopping; delay_ms postpones its first attempt.
fn _job_push(bytes: const u8[:], delay_ms: i64 = 0) -> bool {
    if net::stopping() { return false; }
    return c_jobs_push(bytes, delay_ms) != 0;
}

// A runner's wait for work, up to timeout_ms. On true, out has the job's bytes and the results are its id and
// attempt (from 1); sched has the schedule's name for a scheduled job. On false nothing was appended; a runner
// leaves its loop once net::stopping() is true (the first take after that also stops the scheduler).
fn _job_take(slot: i64, timeout_ms: i64, out: u8[>..]&, sched: u8[>..]&) -> i64, i64, bool {
    var id: i64 = 0;
    var attempt: i64 = 0;
    if net::stopping() { c_jobs_stop(); return 0, 0, false; }
    let got = c_jobs_take(slot as i32, timeout_ms, out, id, attempt, sched);
    return id, attempt, got != 0;
}

// The ctx a job runs with: worker is -1 - slot (never a request worker's index), owner_fd is the runner's owner
// channel, job_id and attempt are set. name is the job's span name (kept in ctx.title); with tracing on the job
// gets a trace of its own, sampled by the configured sampler. hub is cfg.hub, for gweb::publish.
fn _job_ctx(slot: i64, owner_fd: i32, id: i64, attempt: i64, name: const u8[:] = "job", hub: u64 = 0) -> Ctx {
    var ctx = _new_ctx(-1 - slot, owner_fd, hub);   // jobs can gweb::publish to SSE and WebSocket clients
    ctx.job_id = id;
    ctx.attempt = attempt;
    ctx.start_us = c_now_us();
    ctx.title.append(name[..min(name.len, 256)]);
    if c_otel_on() != 0 {
        var trace: u8[>..] = [];
        var sid: u8[>..] = [];
        c_rand_hex(trace, 16);
        c_rand_hex(sid, 8);
        ctx.trace_id.append(trace);
        ctx.span_id.append(sid);
        ctx.sampled = c_otel_sample(-1, trace) != 0;
    }
    return ctx;
}

// Reports the attempt that job_ctx's ctx ran: ok completes the job; false (or a job that returned false) logs a
// warning with job_id and attempt, and the queue tries again later or, after the last attempt, drops the job.
// Ends the job's span when it is sampled.
fn _job_done(slot: i64, ok: bool, ctx: Ctx&) {
    if !ok {
        let e = log_event(ctx, Level.Warn, "job attempt failed");
        log_emit(e);
    }
    if ctx.sampled {
        var attempt: u8[>..] = [];
        format(attempt, ctx.attempt);
        let end_ns = c_unix_ns();
        let dur_us = c_now_us() - ctx.start_us;
        c_span_push(ctx.trace_id, ctx.span_id, "", ctx.title, 1, end_ns - dur_us * 1000, end_ns, if ok { 0 } else { 2 },
                    "", "", "", 0, "job.attempt", attempt, 1);
    }
    c_jobs_done(slot as i32, if ok { 1 } else { 0 });
}

// For a runner thread that aborted: counts the job it held as a failed attempt (the queue retries it) and logs why.
fn _job_abandon(slot: i64, why: const u8[:]) {
    let had = c_jobs_abandon(slot as i32) != 0;
    var msg: u8[>..] = [];
    format(msg, "gweb: job runner ", slot, " aborted: ", why);
    if had { msg.append("; its job will be tried again"); }
    _log_message(Level.Error, msg);
}

fn _schedule_refused(s: Schedules&, name: const u8[:], what: const u8[:]) -> bool {
    s.bad += 1;
    var msg: u8[>..] = [];
    format(msg, "gweb: schedule \"", name, "\": ", what);
    _log_message(Level.Error, msg);
    return false;
}

// Runs the job every ms milliseconds, the first time one interval after start. name is 1 to 32 bytes and unique.
// False (and s.bad goes up, with a log line) when it is refused.
fn _schedule_every(s: Schedules&, name: const u8[:], ms: i64, bytes: const u8[:]) -> bool {
    if ms <= 0 { return _schedule_refused(s, name, "the interval must be above 0"); }
    if !s.enabled { return true; }
    if c_jobs_every(name, ms, bytes) == 0 { return _schedule_refused(s, name, "duplicate or invalid name"); }
    s.n += 1;
    return true;
}

// Runs the job by a five-field cron spec in local time (TZ). False (and s.bad goes up, with a log line) when the
// spec or name is refused; the spec is checked even with --no-schedule.
fn _schedule_cron(s: Schedules&, name: const u8[:], spec: const u8[:], bytes: const u8[:]) -> bool {
    if c_cron_next(spec, time() as i64) < 0 { return _schedule_refused(s, name, "bad cron spec"); }
    if !s.enabled { return true; }
    if c_jobs_cron(name, spec, bytes) == 0 { return _schedule_refused(s, name, "duplicate or invalid name"); }
    s.n += 1;
    return true;
}
