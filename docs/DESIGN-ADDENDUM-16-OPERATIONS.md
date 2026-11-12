<!-- Produced by goose-architect on claude-opus-5-5 (medium) -->
# goose-web decisions: operations (v0.3.0)

Scope, from `BACKLOG.md` "Operations" and "Platform": structured logging, metrics and tracing (OpenTelemetry); health checks, graceful shutdown and zero-downtime restart; Linux and Docker builds, a deploy guide and the Windows status; background jobs and scheduled tasks.

Not in scope, owned by sibling addenda: TLS, HTTP/2, compression and WebSockets (15, delivery); rate limiting, CORS, security headers, sessions (13, auth-security); error pages (14, forms-errors); config files and secrets, Postgres (17, platform); CI and the language server (18, tooling). The platform list in `BACKLOG.md` names "Background jobs and scheduled tasks"; the coordinator gave them to this addendum, so 17 should not design them.

## What the decisions rest on

**Read:** `BACKLOG.md`, `ARCHITECTURE.md`, `DESIGN.md` §5–6 and §10, Addenda 10 (SQLite writes) and 11 (test output), `README.md`, `web.goose`, `owner.goose`, `src/owner.c`, `src/sys.c`, `csrf.goose`, `cli/gweb.goose` (`gen_main`, `gen_dispatch`, `build`, `dev`, `server_cmd`), `cli/proc.c`, goose-net (`net.goose`, `http.goose`, `src/net.c`, `src/loop.c`, `net.build`), goose-sqlite (`sqlite.goose`, the head of `src/sqlite.c`, `sqlite.build`). No sibling addendum existed yet when this was written.

**Facts from the code:**
- `main` listens, runs `state::init`, spawns one `supervisor` per worker, then runs `owner_loop`, which never returns. `print` lines go to stdout. Nothing handles a signal: SIGTERM kills the process mid-response. `gweb dev` restarts the server with SIGTERM (`c_kill(pid, 15)`) and a blocking wait.
- `net::connection_loop` polls the shared listening socket and its connections in C (`gnet_loop_next`), with a 1 s poll timeout. There is no way to make it stop.
- Goose threads share no memory. Flat globals are copied at spawn (Addendum 10, §22 of the Goose reference). Shared process state already lives in C behind a mutex: the goose-sqlite writer claim list. This addendum follows that precedent for metrics, the span ring and the job queue.
- `run_worker` already answers `/__gweb/id` before the dispatcher, so `/__gweb/` is a reserved prefix.
- The `--log` line is `[slot] METHOD target -> status`. No test script greps it.
- Package sub-files (`csrf.goose`, `form.goose`) `import web;`, so the root `web.goose` cannot call into them. Anything `run_worker` calls must be in `web.goose` or in C.
- goose-net already has a plain-HTTP client (`http::get`, `http::post`).
- C sources are POSIX. `SO_NOSIGPIPE` is guarded; `sys.c` includes `sys/random.h` only on Apple (glibc declares `getentropy` in `unistd.h`); `loop.c` sets `_GNU_SOURCE` for `memmem`. goose-sqlite links the system `libsqlite3` (`c_libs = ["sqlite3"]`).

**Facts about this machine:** no `goose` compiler and no `docker` on `PATH`; `cc` (clang), `node` and `python3` are present. So every C part gets a C test harness that runs with `cc`, using a stub `goose.h`. The Goose parts and the Docker files are written, and their tests written, but they are not run here (see the build log).

## Decision 1: process-wide state lives in C, read by Goose through `extern fn`

Metrics counters, the span ring, the job queue and the stop state must be seen by every thread. Goose cannot share memory, and the owner thread is the wrong place: every request would pay an owner round trip (about 9 µs) to bump a counter.

**Choice.** Each of these is a C module with a mutex or atomics, like the goose-sqlite claim list. Goose sees opaque calls. Most logic sits in C, so it is testable without the Goose compiler.

**Rejected:** counters on the owner thread (a round trip per request); per-worker Goose counters merged at scrape (a scrape would need a message to every worker, and workers block in `poll`).

## Decision 2: lifecycle and graceful shutdown (goose-net)

**Choice.** A new goose-net file `lifecycle.goose` (`import net.lifecycle;`, namespace `net`) and `src/lifecycle.c`:

```goose
fn stop_on_signals(delay_ms: i64 = 0, drain_ms: i64 = 10000)  // call first in main, before any thread starts
fn request_stop()                                              // the same as a SIGTERM
fn stop_phase() -> i64      // 0 running, 1 stopping (not ready, still accepting), 2 draining (no new connections)
fn stopping() -> bool       // stop_phase() > 0
fn draining() -> bool       // stop_phase() > 1
fn wait_stop(ms: i64) -> bool                                  // sleeps up to ms; true once stopping
```

- **Signals go to one C thread.** `stop_on_signals` blocks SIGTERM, SIGINT, SIGUSR2 and SIGCHLD with `pthread_sigmask` and starts a C thread that loops on `sigwait`. Threads spawned later inherit the mask, so no Goose thread ever runs a signal handler, and no async-signal-safety rule applies to the code that reacts.
- **First SIGTERM or SIGINT:** phase 1. Readiness turns 503 and connections are still accepted for `delay_ms` (default 0), so a load balancer can stop routing first (the Kubernetes `preStop` pattern). Then phase 2: the C thread writes one byte to a process-wide wake pipe that every loop polls. The C thread then sleeps `delay_ms + drain_ms + 5000` and calls `_exit(1)` with a message, as a hard deadline. It also sends `STOPPING=1` to systemd (Decision 4).
- **A second SIGTERM or SIGINT exits at once** (`_exit(130)`), so Ctrl-C twice always works.
- **The loop drains** (`src/loop.c`, step A2). At phase 2 each loop stops polling the listening socket and the wake pipe, and closes its idle connections. A connection with a whole request buffered is still handed out; `run_worker` then answers with `Connection: close`. A connection with a partial request may finish it until the deadline. When no connection is left, or `drain_ms` has passed since phase 2, the loop closes the rest and returns the new `Event.Stopped`. The listening socket is never closed by a loop, because the other loops (and a handoff child) share it.
- **`run_worker` returns on `Stopped`.** The supervisor does not restart a worker that stops or aborts while `stopping()`.
- **The owner loop ends** when every supervisor has left: a counter in `src/owner.c` (`gweb_chans_leave`) and a quit pipe that `gweb_owner_next` polls; it returns -3, and `owner_loop` returns without the "state channel failed" message.
- **Then `main`** runs the optional `state::shutdown()` (for example a WAL checkpoint), flushes the span exporter, logs how many queued jobs were dropped, and exits 0.

**Why:** the drain uses the poll loop that already exists, adds one fd to it, and changes nothing on the hot path before a stop. Blocking signals and using `sigwait` is the only portable way to react to a signal with ordinary code.

**Rejected:**
- A `sigaction` handler that sets a flag: the loops sleep in `poll` for up to 1 s and would not see it, and nothing but a write to a pipe is safe in a handler anyway.
- Closing the listening socket at phase 2: it breaks the other loops' `poll` and the handoff in Decision 3.
- `sigtimedwait` for the second signal: macOS does not have it.

**Risks:** `--drain-ms` caps a slow handler; past it the connection is cut. A job runner in the middle of a long job holds the exit until the hard deadline.

## Decision 3: zero-downtime restart

Three ways, by environment:

| Where | How | Effect |
|---|---|---|
| Kubernetes, Docker Swarm, Fly, any orchestrator | rolling update; probe `/__gweb/ready`; SIGTERM with `--drain-delay-ms` | true zero downtime; the platform overlaps the processes |
| systemd | `Type=notify`, `ExecReload=kill -USR2 $MAINPID` (the handoff below) | true zero downtime on one host |
| systemd, simpler | a `.socket` unit (socket activation) and `systemctl restart` | no refused connections; requests wait in the kernel backlog during the restart |

**Listener inheritance.** `net::listen_inherited(port, host, backlog) -> Socket, bool` uses fd 3 when `LISTEN_PID` equals `getpid()` and `LISTEN_FDS` is at least 1 (the systemd protocol, which the handoff also uses), checks it with `SO_ACCEPTCONN`, and unsets both variables. Otherwise it listens as today. The `bool` says it was inherited.

**Handoff on SIGUSR2.** `net::enable_handoff(server: Socket, argv: const u8[:])` takes the listener and the process's arguments joined by NUL bytes, and resolves the executable path once (`/proc/self/exe` on Linux, `_NSGetExecutablePath` on macOS). On SIGUSR2 in phase 0, with no handoff child alive, the signal thread:
1. builds the child's environment before `fork` (a copy of `environ` without `LISTEN_FDS`, `LISTEN_PID` and `GOOSE_NET_HANDOFF_PID`, plus those three, with a fixed-width slot for the child's pid);
2. `fork`s. The child does only async-signal-safe work: `dup2(listener, 3)`, closes every fd from 4 up (`close_range` where it exists, else a loop to the `RLIMIT_NOFILE` limit, capped at 65,536), writes its pid digits into the slot, and `execve`s;
3. records the child's pid. A SIGCHLD for that pid before it took over logs `goose-net: handoff failed: the new process exited with status N`, and the old process keeps serving.

The child runs its whole start-up (including `state::init` and migrations) while the old process still serves. Both accept from the same kernel socket. When the child has spawned its workers, it calls `net::ready()`, which sends SIGTERM to `GOOSE_NET_HANDOFF_PID` and, under systemd, sends `MAINPID=<own pid>` and `READY=1`. The old process then drains (Decision 2).

`net::ready()` with no handoff sends only `READY=1` (when `NOTIFY_SOCKET` is set). The systemd notify protocol is one `AF_UNIX` datagram; no libsystemd.

**Why:** a shared kernel socket loses no connection: the backlog is one queue, whoever accepts. `SO_REUSEPORT` gives each process its own queue, and connections waiting in the old process's queue are reset when it closes. The systemd fd protocol is free to support and lets the handoff and socket activation share one code path.

**Rejected:**
- `SO_REUSEPORT` handoff: dropped backlog on close (above), and macOS distributes differently from Linux (`DESIGN.md` §5).
- Handoff by `posix_spawn`: it cannot close the parent's other fds portably (`POSIX_SPAWN_CLOEXEC_DEFAULT` is Apple-only), and an inherited client connection would stay open in the child after the parent closes it.
- Setting `FD_CLOEXEC` on every fd instead: SQLite, socketpairs and user code open fds that the framework does not see.
- Handoff in Docker: when PID 1 exits the container stops. Docker gets the orchestrator row of the table.

**Risks:**
- **Schema changes during an overlap.** The child migrates while the old binary still serves. Migrations must be compatible with the previous release (add columns and tables; drop them a release later). `DEPLOY.md` says so.
- **Two writers** to one SQLite file during the overlap. Addendum 10 already allows another process as a writer (the 1,000 ms busy timeout).
- **Scheduled tasks** can fire in both processes during the overlap (Decision 7).

## Decision 4: health and readiness

`run_worker` answers, before the dispatcher and for GET and HEAD only:

- `/__gweb/health`: `200 ok`, always while the process serves (liveness).
- `/__gweb/ready`: `200 ready`, or `503 stopping` once `net::stopping()` (readiness).

Both have `Cache-Control: no-store` and are left out of the access log and the metrics. `gweb build` fails if `app/` has a folder named `__gweb`.

`server --probe` GETs `http://127.0.0.1:<port>/__gweb/ready` with the goose-net client and exits 0 on 200, else 1. It is the Docker `HEALTHCHECK`, because the slim runtime image has no `curl`.

**Rejected:** `/healthz` and `/readyz` (they take URLs from the app); an app readiness hook (no app needs it yet; see Open questions).

## Decision 5: structured logging

- **Two formats:** `--log-format text` (the default) and `json` (one JSON object per line). Env: `GWEB_LOG_FORMAT`.
- **Levels:** `--log-level debug|info|warn|error` (default `info`). Env: `GWEB_LOG_LEVEL`.
- **Access log:** `--log`, as today. The text line stays `[slot] METHOD target -> status` with ` <N>us` appended. The JSON line has `ts` (RFC 3339 UTC, milliseconds), `level`, `msg: "request"`, `method`, `target`, `route` (the route pattern, `static` or `-`), `status`, `dur_us`, `bytes`, `worker`, `request_id`, and `trace_id` and `span_id` when the request is traced.
- **Request id:** when the access log or tracing is on, `run_worker` takes `X-Request-Id` from the request if it is 1–64 bytes of `[A-Za-z0-9._-]`, else makes 16 hex digits, and returns it as `X-Request-Id`. With both off, no id and no header: the benchmark routes stay byte-identical.
- **App API** (`ops.goose`, `import web.ops;`, generated sites import it always):
  ```goose
  var e = web::log(ctx, web::Level.Info, "order placed");   // a web::LogEvent; carries request_id and trace ids from ctx
  web::field(e, "order_id", id);                           // overloads for i64, f64, bool, const u8[:]
  web::emit(e);
  web::info(ctx, "msg"); web::warn(ctx, "msg"); web::error(ctx, "msg"); web::debug(ctx, "msg");
  ```
  In text format the line is `level msg key=value ...` (values with spaces quoted). A `LogEvent` is a flat struct with a `u8[..2048]` line; a field that does not fit is dropped and the line ends with `truncated=true`.
- **One `write` per line**, to stdout, built in a buffer first, so lines from several threads do not interleave (a pipe write up to 4,096 bytes is atomic on Linux and macOS).
- **The framework's own messages** (start-up line, worker restarts, job failures, shutdown) go through the same writer, so `json` mode emits only JSON. The text start-up line stays `goose-web: http://localhost:PORT (N workers)`.
- Level, format and the access-log switch are flat values in `web::Config`, which every worker gets a copy of; the C side keeps a copy for the job runners and the C modules.

**Rejected:** a `printf`-style variadic logger (Goose has no varargs); writing logs to files (twelve-factor: stdout, the platform collects); OTLP logs (the trace ids in each line give the correlation; see Open questions).

## Decision 6: metrics and tracing

**Metrics: Prometheus text at `/__gweb/metrics`, only with `--metrics`** (env `GWEB_METRICS=1`). The table is in `src/obs.c`, one slot per worker, so workers never contend; the scrape sums the slots.

| Metric | Labels |
|---|---|
| `gweb_http_requests_total` | `route`, `method`, `code` (class: `2xx` … `5xx`) |
| `gweb_http_request_duration_seconds` (histogram: 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, +Inf) | `route` |
| `gweb_http_connections_open` (gauge) | |
| `gweb_jobs_queued`, `gweb_jobs_running` (gauges); `gweb_jobs_completed_total`, `gweb_jobs_failed_total`, `gweb_jobs_dropped_total`, `gweb_jobs_rejected_total` | |
| `gweb_spans_dropped_total` | |
| `gweb_process_start_time_seconds`, `gweb_build_info{version}` | |
| app counters and gauges | name only |

- **Route labels** come from the generated dispatcher: it sets `ctx.route` to the route's index before it calls the handler, and `main` passes the patterns, joined by `\n`, to `web::ops_init`. Static files are `static`; no match is `-`. The label set is bounded by the app.
- **App metrics:** `web::count(name, n)` and `web::gauge(name, v)`. Names must match `[a-z_][a-z0-9_]*`; the table holds 256 names; a new name past that is ignored and counted once in a warning.
- **Off by default**, so a default build adds no work per request beyond one branch.
- The metrics share the main port. `DEPLOY.md` says to block `/__gweb/metrics` at the proxy.

**Tracing: W3C Trace Context and OTLP/HTTP JSON export,** on when `OTEL_EXPORTER_OTLP_ENDPOINT` or `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` is set.
- **Propagation:** a valid `traceparent` sets `ctx.trace_id` and the parent span id; otherwise a new trace id. The sampler is parent-based, with ratio `OTEL_TRACES_SAMPLER_ARG` (default 1.0) for new traces; `OTEL_TRACES_SAMPLER=always_off` turns sampling off. Unsampled requests still get ids, for the logs.
- **Spans:** one server span per request (name `METHOD route`, attributes `http.request.method`, `http.route`, `url.path`, `http.response.status_code`, error status for 5xx). App child spans: `let s = web::span(ctx, "charge card"); ... web::span_end(ctx, s);`. A job run is a span of its own (`job <variant>`). `web::traceparent(ctx, out)` formats the header for an outgoing call.
- **Export:** sampled spans go into a C ring of 8,192 fixed-size records (`src/otel.c`); a full ring drops the span and counts it. A C exporter thread POSTs batches of up to 512 spans, or every second, as OTLP JSON to `<endpoint>/v1/traces`, with `OTEL_SERVICE_NAME` (default `goose-web`) and `OTEL_EXPORTER_OTLP_HEADERS`. Only `http://` endpoints; an `https://` endpoint logs one warning at start and disables export (no TLS client yet; run a local collector). Shutdown flushes for up to 2 s.

**Why:** Prometheus scrape needs no client library and no push; an OpenTelemetry collector can scrape it too. OTLP JSON over HTTP needs no protobuf. Doing both in C keeps them off the Goose hot path and testable here.

**Rejected:** OTLP metrics push (scrape is simpler and standard); protobuf OTLP (a code generator for a binary format); a separate admin port for metrics (another listening loop; deferred); per-status-code labels (class is enough and bounds the table).

**Risks:** the exporter's plain-HTTP POST to a collector that hangs: it uses a 2 s connect and send timeout and drops the batch.

## Decision 7: background jobs and scheduled tasks

**The app writes `app/jobs.goose`:**

```goose
enum Job { Welcome { user: i64 }, Cleanup, Digest }

// Runs on a job runner thread. false, or an abort, is a failed attempt.
fn run(job: const Job&, ctx: web::Ctx&) -> bool {
    match job {
        Welcome w => { ... let r, ok = state::ask(ctx, state::Msg.MarkWelcomed { id: w.user }); return ok; },
        Cleanup => { ... return true; },
        Digest => { ... return true; },
    }
}

fn schedule(s: web::Schedules&) {                               // optional
    jobs::every(s, "cleanup", 5 * 60 * 1000, Job.Cleanup);
    jobs::cron(s, "digest", "0 8 * * 1", Job.Digest);           // 08:00 every Monday, local time (TZ)
}
```

From a handler, the owner, or another job: `jobs::enqueue(ctx, jobs::Job.Welcome { user: id })` or with `delay_ms`. It returns false when the queue is full or the server is stopping; a handler answers 503.

**gweb generates** (in `main.goose`, as it generates `state::ask`): `jobs::enqueue`, `jobs::every`, `jobs::cron`, which serialize the `Job` with `to_bytes` and pass the bytes to C; the `job_runner` and `job_supervisor` thread functions; and the start-up calls. `gweb build` requires a `Job` type and `fn run` in `app/jobs.goose`.

**The queue and the scheduler are in C** (`src/jobs.c`), behind one mutex and condition variable:
- **Capacity** `--job-queue N` (default 10,000). **Runners** `--job-runners N` (default 1; env `GWEB_JOB_RUNNERS`).
- **Retry:** a failed attempt is queued again after `min(1 s × 2^(attempt−1), 5 min)`, up to `--job-attempts N` (default 5); then it is dropped and logged at `error`.
- **An abort** ends the runner thread; its supervisor calls `web::job_abandon(slot, why)`. C still holds the slot's current job, so that counts as a failed attempt and is retried. Nothing is lost to an abort.
- **Each runner has its own owner channel** (index `workers + slot`), so jobs reach `state::ask` and write SQLite through the owner as Addendum 10 requires.
- **Schedules:** `every` first fires one interval after start. `cron` uses five fields (minute, hour, day of month, month, day of week; `*`, lists, ranges, steps; day of month and day of week combine with OR when both are restricted, as in cron) in the process's local time zone (`TZ`; UTC in the Docker image). A schedule whose previous job is still queued or running is skipped that time and logged at `warn`. A bad spec stops start-up with a message.
- **`--no-schedule`** (env `GWEB_SCHEDULE=0`) runs jobs but fires no schedule, for all but one replica.
- **On stop** (phase 1) the scheduler stops and `enqueue` refuses. Runners finish their current job and exit; queued jobs are dropped, and the count is logged.

**Why:** C memory survives the abort of a Goose thread, so the queue does not live in a runner. The queue is in-memory, like the rest of the app's owner state, and adds no dependency.

**Rejected:**
- The queue on the owner thread: every take and every retry would be an owner round trip, and the owner would need timers.
- A SQLite-backed durable queue: it ties gweb to goose-sqlite, and it needs a schema the framework owns. The pattern for durable work is an outbox table that a scheduled job polls; `DEPLOY.md` shows it. See Open questions.
- A thread per job: thread start costs per job, and Goose would need to pass the job's bytes to it.
- Generic schedule entries (`web::every<J>(...)`): generated, typed wrappers follow the `state::ask` precedent and need no generic structs.

**Risks:** jobs and their schedules are lost on a restart (documented). During a handoff overlap a schedule can fire in both processes; for a schedule that must run once, use `--no-schedule` on all but one process, or make the job idempotent.

## Decision 8: Linux, Docker, Windows

**Linux** is a supported target with the same code: every C file is POSIX. Step B7 audits each file for glibc and musl (feature macros, `getentropy`, `close_range`, `SO_NOSIGPIPE`, `MSG_NOSIGNAL`), and `test/linux.sh` runs the suites in a Debian container. The goose compiler must run on Linux to build: Goose builds a native binary on the machine it runs on, and this addendum does not assume cross-compilation.

**Docker:** `gweb new` writes a `Dockerfile` and a `.dockerignore`:
- **Build stage** `debian:bookworm-slim`: `gcc`, `libsqlite3-dev`, `git`, `ca-certificates`, `curl`; the Goose compiler from `ARG GOOSE_URL` (a Linux release tarball; required, see Open questions); goose-web at `ARG GWEB_REF` (default the release tag); `goose build -o gweb cli/gweb.goose`; then `gweb build` in the app.
- **Runtime stage** `debian:bookworm-slim`: `libsqlite3-0`, a non-root user, `COPY .gooseweb/server /app/server`, `WORKDIR /app`, `VOLUME /app/data`, `ENV PORT=3000 TZ=UTC GWEB_LOG_FORMAT=json`, `EXPOSE 3000`, `STOPSIGNAL SIGTERM`, `HEALTHCHECK CMD ["/app/server", "--probe"]`, `CMD ["/app/server"]`.
- The server handles SIGTERM as PID 1 itself (Decision 2), so it needs no `--init`.

**Windows:** not supported natively. The server uses POSIX sockets, `poll`, `socketpair`, pthreads, `fork`/`exec` and signals; `gweb` uses `posix_spawn`, `popen` and `ftw`. Supported routes: WSL2 (the Linux build) and Docker Desktop (the image). A native port would need a Winsock poll loop (or IOCP), a replacement for the socketpair owner channels, console control events instead of signals, and no handoff. It is not planned (see Open questions).

**Deploy guide:** `docs/DEPLOY.md`: build on Linux; the Docker image; systemd units (`deploy/gweb-app.service` with `Type=notify` and `ExecReload`, and `deploy/gweb-app.socket`); a reverse proxy (pointing to Addendum 15 for TLS) with `/__gweb/metrics` blocked; health and readiness; logs and metrics; tracing with a local collector; SQLite on a volume, backups with `VACUUM INTO` and WAL files; zero-downtime restarts and the migration rule; jobs and `--no-schedule`; Windows.

## Config summary

New `web::Config` fields, flags and environment (flags win):

| Field | Flag | Env | Default |
|---|---|---|---|
| `drain_ms` | `--drain-ms N` | `GWEB_DRAIN_MS` | 10000 |
| `drain_delay_ms` | `--drain-delay-ms N` | `GWEB_DRAIN_DELAY_MS` | 0 |
| `log_format` | `--log-format text\|json` | `GWEB_LOG_FORMAT` | text |
| `log_level` | `--log-level L` | `GWEB_LOG_LEVEL` | info |
| `metrics` | `--metrics` | `GWEB_METRICS=1` | off |
| `job_runners` | `--job-runners N` | `GWEB_JOB_RUNNERS` | 1 |
| `job_queue` | `--job-queue N` | | 10000 |
| `job_attempts` | `--job-attempts N` | | 5 |
| `schedule` | `--no-schedule` | `GWEB_SCHEDULE=0` | on |
| | `--probe` | | |

`gweb dev` adds `--drain-ms 200`, so restarts stay fast.

New `web::Ctx` fields, all with defaults so existing literals compile: `route: i64 = -1`, `request_id: u8[..64] = ""`, `trace_id: u8[..32] = ""`, `span_id: u8[..16] = ""`, `parent_span: u8[..16] = ""`, `sampled: bool = false`, `start_us: i64 = 0`, `job_id: i64 = 0`, `attempt: i64 = 0`.

## Files and shared edit regions

**goose-net** (branch `arch/operations`): new `lifecycle.goose`, `src/lifecycle.c`, `test/c/`; changed `src/loop.c` (the drain), `net.goose` (`Event.Stopped` and its mapping), `net.build` (one source), `test/test_net.goose` (appended checks), `README.md`, `CHANGELOG.md`. Addendum 15 also edits `loop.c`; this addendum's change is confined to: one wake-fd slot in the pollfd array, a `draining` flag and deadline in `gnet_loop`, and one branch before `take_ready`. Whoever lands second rebases.

**goose-web** (branch `arch/operations`):
- new: `ops.goose`, `jobs.goose`, `src/obs.c`, `src/otel.c`, `src/jobs.c`, `test/c/`, `test/ops.sh`, `test/ops/site/`, `test/linux.sh`, `docs/DEPLOY.md`, `deploy/`.
- `web.goose`: `Config` and `config_from_args` (new fields and flags only); `Ctx` and `new_ctx` (new fields only); `run_worker` (the health branch beside `/__gweb/id`, timing around `D(...)`, the access-log line, `Stopped`, `keep` under drain); a new section `// ---- operations` at the end of the file for the externs and helpers `run_worker` needs.
- `owner.goose`, `src/owner.c`: the leave counter and quit pipe only.
- `cli/gweb.goose`: `gen_main` (imports, thread functions, the body of `main`), `gen_dispatch` (one `ctx.route = i;` before each handler call), the `app/jobs.goose` checks beside the `app/state.goose` checks in `gen`, the `__gweb` folder check, `server_cmd` (dev `--drain-ms 200`), the `gweb new` file list (Dockerfile, `.dockerignore`).
- `web.build`: the three C sources. `README.md`: a new `## Operations` section before `## SQLite`, and the `--probe`, `--metrics` and other flags in `## Commands`. `CHANGELOG.md`: a `## v0.3.0 (unreleased)` entry. `VERSION` stays.

**goose-sqlite:** no change.

## Build plan

Common rules for every builder:
- Commit locally in the step's worktree, never push, edit only inside that worktree. Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Worktrees: goose-web `/Users/josephheinz/Documents/goose/goose-web/.worktrees/operations`, goose-net `/Users/josephheinz/Documents/goose/goose-net/.worktrees/operations`.
- No comments that restate code or cite this document; why-comments and one-line API notes only, in the style of the file being edited.
- First check for `goose` (or `$GOOSE`) and `docker`. If missing, still write the Goose code, Dockerfiles and test scripts, and run what can run: every C test, `sh -n` on shell scripts, `python3 -m py_compile` on Python. Report what was not run.
- **C tests:** each repo gets `test/c/goose.h`, a stub that defines `gs_rref` and `gs_bld_append` (a growable buffer), and `test/c/run.sh`, which compiles each `test/c/test_*.c` with `cc -std=c11 -Wall -Wextra -Werror -pthread -I test/c` against the sources under test and runs it. A test prints `ok N checks` and exits 0, or names each failure.

### A1. goose-net: lifecycle (Decisions 2, 3)

- **Files:** `lifecycle.goose`, `src/lifecycle.c`, `net.build`, `test/c/goose.h`, `test/c/run.sh`, `test/c/test_lifecycle.c`, `README.md` (a "Lifecycle" section), `CHANGELOG.md`.
- **C API:** `gnet_stop_on_signals(delay_ms, drain_ms)`, `gnet_request_stop()`, `gnet_stop_phase()`, `gnet_wait_stop(ms)`, `gnet_wake_fd()` (the read end, for `loop.c`), `gnet_drain_deadline_ms()` (monotonic ms, or 0), `gnet_listen_inherited(host, port, backlog, *inherited)`, `gnet_enable_handoff(fd, argv_blob)`, `gnet_ready()`. The phase is a C11 atomic. `gnet_request_stop` does the same as the first signal, for tests and `request_stop`.
- **Tests (C):** phases move 0 → 1 → 2 after `delay_ms`; the wake fd turns readable at phase 2; `wait_stop` returns early on stop; a SIGTERM sent with `kill(getpid())` starts the stop (the test thread must have the mask); `listen_inherited` with `LISTEN_FDS=1 LISTEN_PID=<self>` and a listener `dup2`'d to fd 3 returns it and unsets both; with a wrong `LISTEN_PID` it listens fresh; a non-listening fd 3 is refused; the handoff, using a tiny helper program built by `run.sh` as the exec target: the child gets fd 3 as a listening socket, sees `LISTEN_PID` equal to its pid and `GOOSE_NET_HANDOFF_PID` equal to the parent, and no fd above 3 that the parent had open; `ready()` in the child sends SIGTERM to the parent; a child that exits early produces the "handoff failed" message and leaves the parent in phase 0; `ready()` sends `READY=1` to a test `NOTIFY_SOCKET`. The hard-deadline `_exit` is tested in a forked process.
- **Done:** `test/c/run.sh` passes on this Mac; `lifecycle.goose` written (untested if no goose).

### A2. goose-net: loop drain (Decision 2)

- **Files:** `src/loop.c`, `net.goose`, `test/c/test_loop.c`, `test/test_net.goose` (append).
- **Change:** as Decision 2 and the shared-region note; `EV_STOPPED = 6`, `Event.Stopped`.
- **Tests (C, against `loop.c` and `lifecycle.c`):** with two connections, one idle and one with a whole request buffered, `request_stop` with delay 0: the buffered request is still returned, the idle one is closed, then `EV_STOPPED`; a partial request finishes within `drain_ms` and is returned; a partial request past `drain_ms` is dropped and `EV_STOPPED` comes after about `drain_ms`; no new connection is accepted in phase 2 (a `connect` succeeds at TCP level but no request is returned from it); in phase 1 new connections are still accepted. Two loops on one listener both return `EV_STOPPED`. Goose checks appended to `test_net.goose` for the same with `serve` (untested without goose).
- **Done:** `test/c/run.sh` passes.

### B1. goose-web: `src/obs.c` (Decisions 5, 6)

- **Files:** `src/obs.c`, `web.build`, `test/c/goose.h`, `test/c/run.sh`, `test/c/test_obs.c`.
- **C API:** `gweb_now_us()` (monotonic), `gweb_rfc3339(out)` (UTC, ms), `gweb_rand_hex(out, nbytes)` (thread-local xoshiro seeded from `getentropy`; never all zeros), `gweb_log_line(line)` (one `write(1, …)`, retried on a short write), `gweb_log_config(level, json)` and getters, `gweb_metrics_init(workers, route_names_nl)`, `gweb_metrics_on()`, `gweb_metrics_request(worker, route, method, status, dur_us)`, `gweb_metrics_conn(worker, open_count)`, `gweb_metric_count(name, n)`, `gweb_metric_gauge(name, v)`, `gweb_metrics_render(out, version)` (Prometheus text; it calls the job and span counters through weak or linked getters from B2 and B3, so B1 provides stubs that B2 and B3 replace: declare them in a shared `src/ops.h`).
- **Tests:** histogram bucket edges; sums across worker slots; route and method labels; label escaping of `"` and `\` and newlines in route patterns; app metric name validation and the 256 cap; render output parses as Prometheus text (a small Python checker in `test/c/promcheck.py` run by `run.sh`); `rand_hex` lengths and that two threads get different values; `rfc3339` shape.
- **Done:** `test/c/run.sh` passes.

### B2. goose-web: `src/otel.c` (Decision 6)

- **Files:** `src/otel.c`, `src/ops.h`, `web.build`, `test/c/test_otel.c`, `test/c/fake_collector.py`.
- **C API:** `gweb_trace_parse(header, trace_out, parent_out, *sampled)` (W3C rules: version `00`, lower-case hex, no all-zero ids; reject otherwise), `gweb_trace_start(…)` deciding the sample by parent flag or ratio, `gweb_traceparent(out, trace, span, sampled)`, `gweb_span_push(record fields)`, `gweb_otel_start_from_env()` (reads the `OTEL_*` variables; returns 0 when off, 1 when on, 2 when refused for `https`), `gweb_otel_flush(timeout_ms)`, `gweb_spans_dropped()`.
- **Tests:** traceparent parsing table (valid, bad version, upper-case, zero ids, wrong lengths); ratio 0 and 1; the ring drops when full and counts; export to `fake_collector.py` (an HTTP server on a free port that saves bodies): one batch arrives at `/v1/traces` with `Content-Type: application/json`, the JSON parses, it has `resourceSpans[0].resource` with `service.name`, the span's `traceId`, `spanId`, `parentSpanId`, `name`, `kind` 2 (server), times in ns as strings, and attributes; the headers from `OTEL_EXPORTER_OTLP_HEADERS` arrive; a collector that never answers costs at most about 2 s and the batch is dropped; flush on shutdown delivers the remainder.
- **Done:** `test/c/run.sh` passes.

### B3. goose-web: `src/jobs.c` (Decision 7)

- **Files:** `src/jobs.c`, `src/ops.h`, `web.build`, `test/c/test_jobs.c`.
- **C API:** `gweb_jobs_init(runners, cap, attempts)`, `gweb_jobs_push(bytes, delay_ms)`, `gweb_jobs_take(slot, timeout_ms, out, *id, *attempt, *sched_name_out)`, `gweb_jobs_done(slot, ok)`, `gweb_jobs_abandon(slot)` (returns whether a job was current, for the log), `gweb_jobs_every(name, ms, bytes)`, `gweb_jobs_cron(name, spec, bytes)` (0 on a bad spec or duplicate name), `gweb_jobs_stop()` (no more schedules or pushes; `take` returns at once), `gweb_jobs_stat(which)`, `gweb_cron_next(spec, after_unix)` (local time; -1 on a bad spec or nothing within 5 years).
- **Tests:** FIFO order; `delay_ms` respected; capacity refusal; retry with backoff (use an injectable clock: `gweb_jobs_test_clock(fn)`), attempts counted, dropped after the limit; abandon counts as a failure and requeues; two runners never take the same job; `every` fires after its interval and is skipped while its job is pending; cron table: `*/15 * * * *`, `0 8 * * 1`, `0 0 1 * *`, `30 2 * * 1-5`, `0 12 1,15 * *`, day-of-month OR day-of-week, Feb 29 rolls to a leap year, bad specs (`60 * * * *`, `* * *`, `a b c d e`) refused; with `TZ=America/New_York`, a 02:30 daily job on the spring DST day runs at 03:00 local or is skipped to the next day (pick one behaviour, document it in the README, test it); stop wakes a blocked `take`.
- **Done:** `test/c/run.sh` passes.

### B4. goose-web: Goose runtime (Decisions 2, 4–7)

- **Files:** `web.goose` (regions listed above), `ops.goose`, `jobs.goose`, `owner.goose`, `src/owner.c`, `test/c/test_owner_quit.c`.
- **`web.goose`:** the Config table; `--probe` (in `config_from_args`: GET the ready URL on the configured port, exit 0 or 1); Ctx fields; in `run_worker`: the health and ready branch, `ctx.start_us` and the request id and trace start only when access log, metrics or tracing is on, the metrics and span record after `D(...)`, the access line, `X-Request-Id`, `traceparent` not echoed, `keep = keep && !net::draining()`, `Stopped => { lp.free(); return; }`, and the connection gauge from `lp.open_connections()` once per poll wake. The `// ---- operations` section holds the externs for `src/obs.c` and `src/otel.c`, `log_write(level, line)`, and the access-line builder.
- **`ops.goose`** (`import web.ops;`): `Level`, `LogEvent`, `log`, `field` overloads, `emit`, `debug`/`info`/`warn`/`error`, `count`, `gauge`, `Span`, `span`, `span_end`, `traceparent`, `ops_init(cfg, routes_nl)`, `ops_shutdown()`.
- **`jobs.goose`** (`import web.jobs;`): `Schedules`, the externs for `src/jobs.c`, `job_push`, `job_take`, `job_done(slot, ok, ctx)` (logs a failure with job id and attempt, ends the job span), `job_abandon(slot, why)`, `schedule_every`, `schedule_cron`, `job_ctx(slot, owner_fd, id, attempt)`, `jobs_init(cfg)`.
- **`owner.goose`/`owner.c`:** `owner_leave(c: Channels)` (no-op for handle 0), `gweb_owner_next` returns -3 when all have left; `owner_loop` returns quietly on -3.
- **Tests:** `test/c/test_owner_quit.c` (n channels, n leaves, `owner_next` returns -3; a frame still pending before the last leave is served first). Goose: extend `test/owner_test.goose` with a leave check; `test/ops_unit.goose` (new) for the log line shapes in text and JSON (escaping of `"`, `\`, control bytes, non-ASCII passed through), `field` truncation, request-id validation, and `config_from_args` parsing of every new flag (untested without goose).
- **Done:** C tests pass; Goose files written and reviewed against this addendum.

### B5. goose-web: code generation (Decisions 2–4, 7)

- **Files:** `cli/gweb.goose`.
- **`gen_main`:** imports `web.ops` always, `web.jobs` and `jobs` when `app/jobs.goose` exists. The generated wrappers `jobs::enqueue`, `jobs::every`, `jobs::cron`; `ROUTES` as one `\n`-joined literal; `worker` unchanged; `supervisor(slot, server, owner_fd, cfg, chans)` that stops restarting when `net::stopping()` and calls `web::owner_leave(chans)` at the end; `job_runner` and `job_supervisor` as in Decision 7; `main` in the order: `config_from_args`, `net::stop_on_signals(cfg.drain_delay_ms, cfg.drain_ms)`, `net::listen_inherited`, `web::ops_init`, `state::init`, channels for `workers + runners`, `web::jobs_init` and `jobs::schedule` (when defined) and the runners, the workers, `net::enable_handoff(server, <args joined by NUL>)`, `net::ready()`, the start-up line, `owner_loop` or the waits, `state::shutdown` (when defined), `web::ops_shutdown()`, `exit(0)`.
- **`gen_dispatch`:** `ctx.route = <index>;` before each route or page call; the index matches the position in `ROUTES`.
- **`gen`:** `app/jobs.goose` must define `fn run` and a `Job` type (errors in the style of the `state.goose` checks); a folder named `__gweb` anywhere under `app/` is an error.
- **`server_cmd`:** dev adds `--drain-ms 200`.
- **Tests:** the existing suites (`components.sh`, `templates.sh`, `fragments.sh`, `catchall.sh`) must still pass (untested without goose). Add to `test/catchall.sh`-style error checks in B6.
- **Done:** code written; a careful read of the generated `main.goose` text for one site with state and jobs, written out by hand in the commit message's body or a scratch file, matches Decision 2's order.

### B6. goose-web: the operations suite

- **Files:** `test/ops.sh`, `test/ops/site/` (`app/state.goose` with a counter and `shutdown` writing a marker file; `app/jobs.goose` with `Bump` (asks the owner to add 1), `Fail` (returns false), `Boom` (aborts) and an `every` schedule of 1,000 ms; `app/slow/route.goose` that sleeps 1,500 ms; `app/enqueue/[kind]/route.goose`; `app/count/route.goose`; `app/page.html`).
- **Checks:** `/__gweb/health` 200, `/__gweb/ready` 200, HEAD works; `/__gweb/metrics` 404 without `--metrics` and valid Prometheus text with it, with the route labels; `--log --log-format json` lines parse as JSON with the documented keys; `X-Request-Id` echo and refusal of a bad one; enqueue `Bump` → count rises; `Fail` → logged retries, `gweb_jobs_failed_total` rises; `Boom` → "aborted" logged, the server still answers, the job retried; the schedule raises the count over 3 s; SIGTERM during `/slow`: `/__gweb/ready` turns 503 when `--drain-delay-ms 1000`, the slow request still completes with 200, a new connection after the delay is refused or reset, the process exits 0 and the `shutdown` marker exists; SIGTERM twice exits at once; SIGUSR2: a new pid serves, the old pid exits, and a loop of requests during the handoff sees no failure; the handoff with a child that fails `init` (`OPS_FAIL_INIT=1` in the environment of the old process's second start) leaves the old process serving; a site with `app/jobs.goose` missing `fn run`, and one with `app/__gweb/`, fail `gweb build` with their messages; `server --probe` exits 0 while up and 1 when not.
- **Done:** `sh -n test/ops.sh` passes; the suite runs where goose is present (untested here).

### B7. goose-web: Linux, Docker, deploy guide, docs

- **Files:** `cli/gweb.goose` (`gweb new` files: `Dockerfile`, `.dockerignore`), `deploy/gweb-app.service`, `deploy/gweb-app.socket`, `deploy/Dockerfile` (the same template, for reading), `docs/DEPLOY.md`, `test/linux.sh`, `README.md`, `CHANGELOG.md`, and Linux fixes in any C file of goose-web (goose-net C fixes go to the goose-net worktree in a separate commit; goose-sqlite C fixes are reported, not made, unless trivial, in a goose-sqlite worktree cut as this addendum's instructions say).
- **Audit:** every C file in the three repos for Linux (glibc and musl): feature-test macros, headers, `getentropy`, `SIGPIPE` on `send` (use `MSG_NOSIGNAL` where `SO_NOSIGPIPE` is missing, or rely on the process-wide ignore and say so), `close_range`, `_NSGetExecutablePath` guarded. Compile each with `cc -fsyntax-only` here; list what only Linux can confirm.
- **`test/linux.sh`:** given `GOOSE_URL`, builds a Debian container, installs the toolchain, builds `gweb`, runs every suite including `test/c/run.sh` in both repos and `test/ops.sh`, and builds the starter site's Docker image and probes it.
- **Done:** files written; `sh -n` on scripts; `systemd-analyze verify` is not available here, so the units are checked by reading; the Dockerfile is checked by reading against Decision 8.

## Open questions for the user

1. **Goose on Linux.** Is there a Linux release of the Goose compiler, and at what URL? The Dockerfile takes it as a required `ARG GOOSE_URL`. Default: required argument, no URL guessed.
2. **Durable jobs.** The queue is in memory and lost on restart (chosen), or a SQLite-backed queue in goose-web that depends on goose-sqlite.
3. **Windows.** WSL2 and Docker only (chosen), or plan a native port.
4. **Metrics exposure.** On the main port behind `--metrics` (chosen), or a separate admin port bound to 127.0.0.1.
5. **App readiness hook.** None (chosen), or an optional `fn ready() -> bool` in `app/state.goose` that `/__gweb/ready` calls through the owner.
6. **Logs over OTLP.** stdout only, with trace ids in each line (chosen), or also export logs to the collector.
7. **Version.** These features are a minor release, v0.3.0 (chosen).

## Build log

Branch `arch/operations` in all three repos. Nothing pushed. A Goose compiler (v2026.4) arrived mid-build; every step was then compiled and tested. Docker is not installed.

| Step | Repo, commits | Tested |
|---|---|---|
| A1 lifecycle | goose-net `20f9ef9`, `02ac9e4` (SIGPIPE ignore on inherited listeners) | C 43 checks; `test_net` 151/151 |
| A2 loop drain | goose-net `d98a7a6` | C 32 checks; `test_net` |
| B1 `obs.c` | goose-web `db0ed83` | C 85 + 8 checks, also under TSan and ASan/UBSan |
| B2 `otel.c` | goose-web `8419977` | C 154 checks against a fake collector |
| B3 `jobs.c` | goose-web `0cb3cd0` | C 184 checks, TSan and ASan/UBSan |
| B4 Goose runtime | goose-web `7e46e70`, fixes `8c32f93` | `ops_unit` 78, `owner_test`, C owner 14 |
| B5 codegen | goose-web `89dcd17`, plus a newline fix in the build-log commit | all suites; `ops.sh` |
| B6 `test/ops.sh` | goose-web `4f074e4` | 72/72, 6 serial and 3 parallel runs |
| B7 deploy, docs, Linux audit | goose-web `dc488ff`; goose-sqlite `5cd1cf0` (`strlcpy` breaks glibc < 2.38) | not run: no Docker, no Linux |

Suites on the final tree: components 46/46, templates 33/33, fragments 82/82, catchall 50/50, morph 21/21, cookie 59/59, csrf 52/52, catchall_test 62/62, ops 72/72, goose-sqlite all pass. Not run: `release_check.sh` and `linux.sh` (worktree layout and Docker), systemd units, Docker image, OTLP against a real collector, cron inside a running site, Linux paths (`/proc/self/exe`, `close_range`, glibc/musl).

Deviations, each recorded in the commits:
- `Level` lives in `web.goose`, since `run_worker` needs it. `config_from(a)` is split out of `config_from_args` for tests and copies `args()` (Goose does not convert `u8[:][>..]` to `(const u8[:])[:]`).
- `run_worker` takes the `\n`-joined `ROUTES` as a defaulted parameter; `/__gweb/metrics` is served from `run_worker`.
- App metric names starting `gweb_` are refused; gauges take f64.
- macOS: `SO_ACCEPTCONN` is unsupported, so `listen_inherited` falls back to a `getpeername` check there; a no-op SIGCHLD handler keeps the signal pending for `sigwait`.
- `http::serve` also returns on `Stopped`.
- Cron DST: a local time that does not exist is skipped; a repeated one fires once, at its first occurrence. `*/n` in day-of-month or day-of-week counts as unrestricted for the OR rule, as in Vixie cron.
- `job_push` refuses once `net::stopping()`; schedule errors set `Schedules.bad` and `main` exits 1.
- The text access line prints the status as `200 OK`, as the old line did.

Found, not fixed: `accept_all` in goose-net `loop.c` returns on any accept error, so `EMFILE` would spin the loop.
