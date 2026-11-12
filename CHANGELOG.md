# Changelog

## v0.3.0 (unreleased)

- Operations: `/__gweb/health` and `/__gweb/ready`; graceful shutdown on SIGTERM and SIGINT (`--drain-ms`, `--drain-delay-ms`); SIGUSR2 and systemd socket activation restart without dropping a request (`net.lifecycle` in goose-net).
- Logs: `--log-format json`, `--log-level`, request ids, and `web::info`, `web::log` and friends.
- Metrics (`--metrics`, Prometheus text at `/__gweb/metrics`) and OpenTelemetry tracing (OTLP/HTTP JSON, `traceparent`).
- Background jobs and schedules: `app/jobs.goose`, `jobs::enqueue`, `jobs::every`, `jobs::cron`, `--no-schedule`.
- Linux and Docker: a Dockerfile and `.dockerignore` for new apps, systemd units in `deploy/`, `test/linux.sh`, and `docs/DEPLOY.md`. Windows is supported through WSL2 and Docker only.
- Behaviour change: `/__gweb/` is reserved; an `app/__gweb` folder is a build error.

## v0.2.1

- Fix: `gweb test` no longer deletes `.gooseweb/`; it generates into `.gooseweb.test/`. Add `.gooseweb.test/` to `.gitignore`.

Pins goose-net v0.2.1 and goose-sqlite v0.2.1.

## v0.2.0

- Breaking: CSRF tokens are on by default. Every page `fn POST` and every `route.goose` `POST`, `PUT`, `PATCH` or `DELETE` answers 403 until its forms add `@web::csrf_field(ctx)`, or the route declares `const CSRF = false;`. `Sec-Fetch-Site: same-site` is refused as well as `cross-site`, and `web::cross_site` is removed.
- Catch-all routes: a `[...name]` folder matches one or more trailing segments and `[[...name]]` zero or more. `web::param` returns the raw tail, and `web::path_decode` decodes it. A tail over 1,024 bytes, or with an empty or dot segment, `%2F`, `\` or a control byte, gets a 404.
- Behaviour change: `public/` files are now tried before every route for GET and HEAD. A public file that an `[id]` route at the same depth used to shadow is now served. A route that has the same URL as a public file is still a build error.
- A route folder deeper than 16 folders is now a build error; it was silently never matched.
- Keyed morph: `gw-key` keeps element identity and focus when list items move, appear or disappear.
- SQLite writes: the owner-thread writer pattern, documented, with the shop's `/db/todos` demo; needs goose-sqlite v0.2.0.

Pins goose-net v0.2.0 and goose-sqlite v0.2.0.

## v0.1.1

The repos moved from `jheinz-bzs` to `josephheinz`. `gweb` now pins `josephheinz/goose-*@v0.1.1`.

Pins goose-net v0.1.1 and goose-sqlite v0.1.1.

## v0.1.0

First tagged release: file-based routes, templates, components, fragments, cookies, owner state, and the `gweb` command line.

Pins goose-net v0.1.0 and goose-sqlite v0.1.0.
