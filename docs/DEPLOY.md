# Deploying goose-web

An app builds to one native binary, `.gooseweb/server`. It serves plain HTTP, reads a few flags and
environment variables, and writes logs to stdout. Design: [DESIGN-ADDENDUM-16-OPERATIONS.md](DESIGN-ADDENDUM-16-OPERATIONS.md).

## Build on Linux

Goose builds a native binary on the machine it runs on, so build on Linux for Linux. You need a Linux
Goose compiler, `gcc`, `libsqlite3-dev` (only when the app uses SQLite) and `git`.

```
goose build -o gweb cli/gweb.goose        # once, in a goose-web checkout
GOOSE=/path/to/goose gweb build           # in the app
.gooseweb/server --port 3000
```

Debian and Ubuntu (glibc) are the tested targets. Alpine (musl) should work and is not tested.
The server needs `libsqlite3` at run time when the app uses SQLite.

## Docker

`gweb new` writes a `Dockerfile` and a `.dockerignore` (also in `deploy/`). The Dockerfile has two stages:
the build stage installs the toolchain, fetches the Goose compiler, builds `gweb` and the app; the runtime
stage holds the binary and `libsqlite3-0`.

```
docker build --build-arg GOOSE_URL=<Linux goose release tarball> -t mysite .
docker run -d --name mysite -p 3000:3000 -v mysite-data:/app/data --stop-timeout 30 mysite
```

- `GOOSE_URL` is required. The build stops with a message when it is empty.
- `GWEB_REF` picks the gweb tag that builds your app (default `v0.4.0`; keep it equal to the version you develop with).
- The container runs as a non-root user (uid 10001). `/app/data` is a volume owned by it. A named volume
  copies that ownership; for a bind mount run `chown 10001 <dir>`.
- `ENV PORT=3000 TZ=UTC GWEB_LOG_FORMAT=json`. Add flags after the image name or set `GWEB_*` variables.
- The server handles SIGTERM as PID 1, so no `--init` is needed. `docker stop` waits 10 s by default; with
  the default drain of 10 s plus a 5 s deadline, use `--stop-timeout 30`.
- `HEALTHCHECK` runs `/app/server --probe`, which GETs `/__gweb/ready` on `127.0.0.1`. The slim image has no `curl`.
- A zero-downtime restart in Docker needs an orchestrator that overlaps two containers (below). The SIGUSR2
  handoff does not work here: when PID 1 exits, the container stops.

### Kubernetes

```yaml
containers:
  - name: app
    args: ["--drain-delay-ms", "5000"]       # keep serving while the load balancer notices
    readinessProbe: { httpGet: { path: /__gweb/ready, port: 3000 } }
    livenessProbe:  { httpGet: { path: /__gweb/health, port: 3000 } }
terminationGracePeriodSeconds: 35            # drain delay + drain + 5 s
```

## systemd

`deploy/gweb-app.service` runs the binary as a dedicated user with `Type=notify`; its header lists the
install steps. `deploy/gweb-app.socket` is optional.

| Command | Effect |
|---|---|
| `systemctl reload gweb-app` | SIGUSR2. A new process takes the same listening socket and starts (migrations included) while the old one serves; then the old one drains and exits. No request fails. |
| `systemctl restart gweb-app` | Stop, then start. With `gweb-app.socket`, new connections wait in the kernel backlog. Without it they are refused for the gap. |

`systemctl stop` sends SIGTERM and waits `TimeoutStopSec=30`. A second SIGTERM or Ctrl-C exits at once.
The unit's hardening options keep `fork`/`exec` (the reload) and the data directory working; if you add a
`SystemCallFilter` or `MemoryDenyWriteExecute`, test `reload` afterwards.

## Reverse proxy

**TLS is not served by goose-web and is not covered here.** It is the subject of
[Addendum 15](DESIGN-ADDENDUM-15-DELIVERY.md) (delivery). Until then, terminate TLS at a proxy and pass
`X-Forwarded-Proto` (the CSRF cookie becomes `__Host-gw_csrf` with `Secure` behind `https`).

Block `/__gweb/metrics` from outside: it shares the main port. Let Prometheus scrape `127.0.0.1:3000` directly.

Caddy (TLS is automatic):

```
example.com {
    @metrics path /__gweb/metrics
    respond @metrics 404
    reverse_proxy 127.0.0.1:3000
}
```

nginx (add your own `listen 443 ssl` and certificates):

```nginx
server {
    server_name example.com;
    location = /__gweb/metrics { return 404; }
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Behind a proxy, set `--drain-delay-ms` so a deploy tells the proxy first (readiness turns 503) while the
server still accepts.

## Health and readiness

| URL | Answer |
|---|---|
| `/__gweb/health` | `200 ok` while the process serves (liveness). |
| `/__gweb/ready` | `200 ready`, or `503 stopping` once a stop began (readiness). |

GET and HEAD only, `Cache-Control: no-store`, left out of the access log and metrics. `/__gweb/` is reserved:
`gweb build` fails on an `app/__gweb` folder. `server --probe` exits 0 when `/ready` answers 200, else 1.

## Logs and metrics

Logs go to stdout, one line per event, one `write` per line. `--log-format json` (or `GWEB_LOG_FORMAT=json`)
makes every line JSON, the framework's own messages included. `--log` turns on the access log; with it, and with
tracing, each response carries `X-Request-Id`. Levels: `--log-level debug|info|warn|error`. Let Docker, journald
or your platform collect stdout; the app writes no log files.

Access line, JSON: `ts`, `level`, `msg: "request"`, `method`, `target`, `route`, `status`, `dur_us`, `bytes`,
`worker`, `request_id`, and `trace_id` and `span_id` when traced.

From your code: `gweb::info(ctx, "msg")`, `gweb::warn`, `gweb::error`, `gweb::debug`; add fields with
`var e = gweb::log(ctx, gweb::Level.Info, "order placed"); gweb::field(e, "order_id", id); gweb::emit(e);`.

`--metrics` (or `GWEB_METRICS=1`) serves Prometheus text at `/__gweb/metrics`: request counts by route, method
and status class, a latency histogram per route, open connections, job gauges and counters, and
`gweb_build_info`. Count your own things with `gweb::count("signups_total", 1)` and `gweb::gauge("queue_depth", n)`
(names match `[a-z_][a-z0-9_]*`; 256 at most).

```yaml
scrape_configs:
  - job_name: app
    static_configs: [{ targets: ["127.0.0.1:3000"] }]
    metrics_path: /__gweb/metrics
```

## Tracing

Set `OTEL_EXPORTER_OTLP_ENDPOINT` (or `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`) and the server exports spans as
OTLP/HTTP JSON to `<endpoint>/v1/traces`. It reads `traceparent` and adds `trace_id` and `span_id` to the
logs.

- Only `http://` endpoints. There is no TLS client: run an OpenTelemetry Collector on the same host or as a sidecar
  and let it forward over TLS. An `https://` endpoint logs one warning and turns export off.
- `OTEL_SERVICE_NAME` (default `goose-web`), `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_TRACES_SAMPLER=always_off`,
  `OTEL_TRACES_SAMPLER_ARG` (ratio for new traces, default 1.0).
- App spans: `let s = gweb::span(ctx, "charge card"); ... gweb::span_end(ctx, s);`. For an outgoing call,
  `gweb::traceparent(ctx, out)` formats the header.
- A full buffer (8,192 spans) drops spans and counts them in `gweb_spans_dropped_total`. A collector that hangs
  costs at most 2 s per batch.

## SQLite

- Keep the database file on a volume (`/app/data`, or a directory the service user owns). Image layers are lost
  with the container.
- WAL mode keeps `app.db-wal` and `app.db-shm` beside `app.db`. Do not copy `app.db` alone from a running
  server: it misses what is still in the WAL.
- Back up with SQLite itself, which gives one consistent file and can run while the server serves:

  ```
  sqlite3 data/app.db "VACUUM INTO '/backups/app-$(date +%F).db'"
  ```

  The target file must not exist. In Docker, run it from the host against the volume path, or from a throwaway
  container that mounts the volume and has `sqlite3`. Copying all three files after a stop also works.
- Run one server per database file. During a reload two processes briefly share it; that is supported
  (writers wait up to 1 s on a busy lock).

## Zero-downtime restarts

| Where | How | Effect |
|---|---|---|
| Kubernetes, Swarm, Fly, any orchestrator | rolling update, probe `/__gweb/ready`, SIGTERM with `--drain-delay-ms` | no downtime; the platform overlaps old and new |
| systemd | `systemctl reload` | no downtime on one host |
| systemd, simpler | `gweb-app.socket` and `systemctl restart` | no refused connection; requests wait for the new process |

**The migration rule.** The new process migrates while the old binary still serves, so a migration must keep
the previous release working: add columns and tables; drop or rename them one release later.

**What overlaps.** Two writers for a short time (SQLite handles it), and scheduled jobs can fire in both
processes (next section). In-memory job queues and owner state are not carried over.

A reload whose new process fails to start (a bad migration, a crash) leaves the old one serving; the failure is
in the log as `goose-net: handoff failed: ...`.

## Background jobs

A job queue lives in memory. Jobs queued or scheduled at a restart are lost; the stop logs how many were dropped.
Retries (5 attempts, 1 s doubling to 5 min) and aborts are handled; a restart is not.

- `--job-runners N` (default 1), `--job-queue N` (10,000), `--job-attempts N` (5).
- With several replicas, run `--no-schedule` (or `GWEB_SCHEDULE=0`) on all but one so a schedule fires once.
  Make jobs idempotent anyway: during a reload a schedule can fire in both processes.
- A job that runs longer than the drain holds the exit up to the hard deadline.

**Durable work: the outbox.** For work that must not be lost (an email after a signup), do not rely on the queue.
Write a row in the same transaction as the change, and let a scheduled job do the sending.

```
create table outbox (id integer primary key, kind text not null, payload text not null,
                     created integer not null, done integer);
```

1. The handler asks the owner to commit the change and an `outbox` row together (one `sqlite::begin` / `commit`).
2. `jobs::every(s, "outbox", 5000, Job.Outbox)` runs `Job.Outbox` every 5 s.
3. `Outbox` asks the owner for rows where `done is null` (oldest first, a small batch), performs each, and asks the
   owner to set `done`. A failure leaves the row for the next run.
4. Because a crash between step 3's send and mark repeats the send, the action must tolerate a repeat (an idempotency key).

An in-memory `jobs::enqueue` after the commit is fine as a speed-up on top of the outbox.

## Config summary

Flags win over environment variables.

| Flag | Env | Default |
|---|---|---|
| `--port N` | `PORT` | 3000 |
| `--workers N` | `WEB_WORKERS` | min(performance cores, 4) |
| `--log` | | off |
| `--log-format text\|json` | `GWEB_LOG_FORMAT` | text |
| `--log-level L` | `GWEB_LOG_LEVEL` | info |
| `--metrics` | `GWEB_METRICS=1` | off |
| `--drain-ms N` | `GWEB_DRAIN_MS` | 10000 |
| `--drain-delay-ms N` | `GWEB_DRAIN_DELAY_MS` | 0 |
| `--job-runners N` | `GWEB_JOB_RUNNERS` | 1 |
| `--job-queue N` | | 10000 |
| `--job-attempts N` | | 5 |
| `--no-schedule` | `GWEB_SCHEDULE=0` | schedules on |
| `--probe` | | exits 0 or 1 and stops |

Environment only: `TZ` (cron time zone; `UTC` in the Docker image), `OTEL_*` (see Tracing).
Signals: SIGTERM or SIGINT drain and exit; SIGUSR2 hands over to a new process (systemd `reload`).

## Windows

Not supported natively: the server uses POSIX sockets, `poll`, `socketpair`, pthreads, `fork`/`exec` and signals,
and `gweb` uses `posix_spawn`, `popen` and `ftw`. Use WSL2 (the Linux build above) or Docker Desktop (the image).
A native port is not planned.
