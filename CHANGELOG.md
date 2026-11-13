# Changelog

## v0.7.0 (unreleased)

Made ready for a CMS package (Addendum 20). The integration fixture is `test/cmsready/`.

- `gweb::send_file(req, ctx, res, root, rel, opts)` in `gweb.http.files`: serves a file under a root with `Content-Type`, `ETag` and 304, `Cache-Control` (immutable or revalidate), HEAD, `Content-Disposition`, and a window stream above `stream_over`. Refuses `..`, dotfiles and symlinks out of the root. Also `gweb::mime_type`, `gweb::file_path_ok`, `gweb::FileOptions`.
- `gweb.packages` takes git URLs: `file:///path/repo.git@tag` and `https://host/path@tag`, cloned into the package cache under `url/`.
- Views: `validate` errors get the form prefix, so the generated form shows them. `g_parse` writes the JSON it read after an error, so a form can be drawn again as typed.
- Route tests: `t.host` sets the `Host` header.

## v0.6.0

Library work toward v1 (the gweb side of the CMS design, Addendum 19).

- Views: `views/<group>/<Name>.goose` and `.html` get a generated JSON codec, admin form, form parser and a by-name registry (`import views;`). `@slot("x")` holes, `gweb::ViewMeta`, `FieldUi`, `Renamed`. A package's `views/` merges. See DESIGN-ADDENDUM-19.
- `gweb::markdown(out, src)` and `gweb::markdown_text(out, src, max)`: a safe Markdown subset in Goose.
- `gweb::cache_serve_key`, `cache_store_key` and `epoch_bump()`: your own page-cache keys, and one call that clears every worker's cache.
- `gweb::sitemap_base(s, url)` and an optional `fn robots(req, ctx, out)` in `app/sitemap.goose`.
- `gweb::reserved_prefixes()` is generated into `main.goose`.
- `export { morph }` in `gwi.js` (`gwi.min.js` is 4,079 bytes).
- `app/state.goose` may declare `const VARIABLE_MSG = true;` to send a `Msg` with a variable-size payload (`Msg..`).
- Nested package mounts (`/admin/shop` inside `/admin`) are documented and tested.

## v0.5.1

First release built and tested by CI on macOS and Linux. No API change.

- Linux: test fixes for dash (a reaped server counted as running) and for `usleep` under `-std=c11`.
- `ops.sh` sends its 20 handoff requests however slow the machine.

## v0.5.0

- Breaking: environment variables are `GWEB_*`: `GWEB_SECRET`, `GWEB_CSP`, `GWEB_WORKERS`, `GWEB_TRUST_PROXY`, `GWEB_HSTS`, `GWEB_SESSION_IDLE`, `GWEB_SESSION_MAX`, `GWEB_SECURITY_HEADERS`. The server refuses to start while an old `WEB_*` name is set. `sh tools/migrate-v0.5.sh` renames them in `.env` files, units and Dockerfiles.
- Breaking: `GOOSE_WEB_HOME` is `GWEB_HOME`, and `GWEB_WEB` is `GWEB_SRC`.
- Server log lines start with `gweb:` (was `goose-web:`).
- CI: GitHub Actions test all three repos on macOS and Linux and publish a release for each `v*` tag.

## v0.4.0

Breaking: the package is `gweb` and its modules are in folders. `sh tools/migrate-v0.4.sh` in an app rewrites its imports and calls.

- The repository is `josephheinz/gweb` (was `goose-web`). `import gweb from "josephheinz/gweb@v0.4.0";`
- `web::` is `gweb::`, and `import web;` is `import gweb;`.
- Modules moved:

  | v0.3 | v0.4 |
  |---|---|
  | `web.session`, `crypto`, `csrf`, `rate`, `cors` | `gweb.auth.*` |
  | `web.form`, `valid`, `upload` | `gweb.forms.*` |
  | `web.cache`, `static`, `stream`, `push` | `gweb.http.*` |
  | `web.template`, `meta`, `sitemap`, `i18n`, `errors` | `gweb.site.*` |
  | `web.ops` | `gweb.ops.log` |
  | `web.jobs`, `owner` | `gweb.ops.*` |
  | `web.testing` | `gweb.testing` |

- goose-net and goose-sqlite are tagged v0.4.0 with no code change.

## v0.3.0

Needs the matching goose-net release (spool mode, `net::Hub`, `Loop.detach`, chunked responses, `http::accepts`, `net.lifecycle`).

- Forms: a `*Form` struct in `page.goose` or `route.goose` gets a generated `decode`. New `web::valid`: `FieldErrors`, `check_email`, `check_range`, `check_length`, `check_one_of`, `field_error`, `invalid`, `field_value`, `errors_json`, `set_status`, `unprocessable`.
- 422: a form with errors answers 422. `gwi.js` morphs a 422 fragment reply instead of refusing it.
- Uploads: multipart posts, `web::Upload`, `save_upload`, `check_upload`, `const MAX_UPLOAD`. Flags `--max-upload N` (default 32 MiB) and `--upload-dir D` (default `.gooseweb.uploads`). Large bodies are spooled to disk. `gw-target` forms with `enctype="multipart/form-data"` send `FormData`.
- Error pages: `error.html` (nearest wins) and `web::fail`. A crashed request now gets the error page instead of hanging; `gweb dev` shows the abort text and source lines. Build errors in the dev overlay get source lines.
- `loading.html` and `gw-loading`: a loading state for slow fragment requests.
- A page `fn POST` or `fn load` may take `res`; `web::done(ctx)` ends the reply itself.
- Breaking: `web::Outcome` has two new variants, `Error` and `Done`. An exhaustive `match` on it needs arms for both.
- Behaviour change: when a worker crashes, its other keep-alive connections are now closed (they leaked before). Clients reconnect.
- `.env` files (`.env.<env>.local`, `.env.local`, `.env.<env>`, `.env`), `WEB_SECRET` with rotation, and typed `web::env_*` helpers.
- Signed cookies and stateless sessions: `web::login`, `logout`, `session`, `require_login`, `require_login_api`, `safe_next`.
- PBKDF2-HMAC-SHA-256 passwords: `web::password_hash`, `password_verify`, `password_needs_rehash`.
- Rate limits shared by all workers: `web::rate_limit`, `rate_limit_key`; `WEB_TRUST_PROXY` for `client_ip`.
- CORS: `web::cors`.
- CSP with a per-request nonce, opt-in with `WEB_CSP`; `web::nonce` for templates; optional `WEB_HSTS`.
- Behaviour change: every response now carries `X-Content-Type-Options`, `Referrer-Policy` and `X-Frame-Options` headers. Opt out with `WEB_SECURITY_HEADERS=0`.
- Behaviour change: `web::login` rotates the CSRF token.
- Apps that use sessions refuse to start in production without `WEB_SECRET`.
- `/_gw/` runtime modules stay at plain URLs (revalidated), so each module loads once.
- Behaviour change: `gweb build`, `start` and `export` minify `public/**/*.css`. `gweb dev` does not. Pass `--no-minify` to keep the files as written.
- Static files are served at a hashed URL too (`/css/site.3f9a1c2b.css`) with `Cache-Control: public, max-age=31536000, immutable`. The plain URL is unchanged. A hashed URL that equals another URL is a build error.
- Text static files of 1 KB or more get a gzip variant at build time, sent to clients that accept it. gweb now links zlib.
- `@asset("/path")` writes the hashed URL; `web::asset_url(path)` does the same at run time.
- `@image(path, alt[, attrs])` writes an `<img>` with its size read at build time, lazy loading and an `@2x` `srcset`.
- `ctx.meta` with `web::meta_description`, `meta_canonical`, `meta_image` and `meta_robots`, and `@meta()` in `layout.html` for description, canonical, robots, Open Graph and Twitter tags. `web::site_url(req, out)` and the `SITE_URL` variable give the base URL.
- `app/sitemap.goose` turns on `/sitemap.xml` and `/robots.txt`; `web::sitemap_add` adds entries and `const SITEMAP = false;` leaves a page out.
- `const REVALIDATE = N;` in `page.goose` caches a page's GET reply per worker for N seconds, with an ETag. A page that uses a CSRF token cannot have it.
- `gweb export [-o DIR]` writes the site as static files. A dynamic page lists its paths in `fn static_paths()`.
- Streaming responses: `web::stream_begin`, `web::write` and `web::end(ctx, s)`.
- Server push: `web::subscribe` (SSE) and `web::websocket`, with `web::publish`, `web::send`, `web::close_socket` and `web::subscribers`, over one `net::Hub` thread. `app/socket.goose` handles `open`, `message` and `close`. `web::websocket` refuses a cross-origin `Origin`.
- New `Config` flag `--export DIR`; new `Ctx` fields `meta`, `hub`, `conn_fd`.
- New `docs/DEPLOY-PROXY.md`: Caddy and nginx in front of goose-web.
- Route tests: `web.testing` and `tests/*.goose`, run by `gweb test` against the real dispatcher with no socket.
- i18n: `locales/<tag>.txt` catalogs compile to a typed `t::` module; the locale comes from the `locale` cookie or `Accept-Language`.
- Operations: `/__gweb/health` and `/__gweb/ready`; graceful shutdown on SIGTERM and SIGINT (`--drain-ms`, `--drain-delay-ms`); SIGUSR2 and systemd socket activation restart without dropping a request (`net.lifecycle` in goose-net).
- Logs: `--log-format json`, `--log-level`, request ids, and `web::info`, `web::log` and friends.
- Metrics (`--metrics`, Prometheus text at `/__gweb/metrics`) and OpenTelemetry tracing (OTLP/HTTP JSON, `traceparent`).
- Background jobs and schedules: `app/jobs.goose`, `jobs::enqueue`, `jobs::every`, `jobs::cron`, `--no-schedule`.
- Linux and Docker: a Dockerfile and `.dockerignore` for new apps, systemd units in `deploy/`, `test/linux.sh`, and `docs/DEPLOY.md`. Windows is supported through WSL2 and Docker only.
- Jobs can `web::publish` to SSE and WebSocket clients.
- Behaviour change: `/__gweb/` is reserved; an `app/__gweb` folder is a build error.
- Reactive components: `@prop`, `@state`, `@computed`, `@watch`. gweb finds which markup reads which names and, after a handler, updates only those text nodes, attribute lists and `{#if}`/`{#for}` blocks. Markup names state directly (`{count}`). A throwing handler leaves the page unchanged. `struct State` components still work.
- Pages call reactive components with named props: `@Counter(start: 3, label: p.name)`.
- Async handlers: `await http::get` and `http::post` with typed replies. A failure restores what the handler wrote and raises `gw:error`.
- Lifecycle: `@mount`, `@unmount`, `@every(ms)`.
- Events: `dblclick`, `keydown`, `keyup`, `focus`, `blur`, and modifiers `on:keydown.enter.prevent`, `stop`, `300ms`.
- Nested components with props (`@Card(title: x, key: id)`) and child events (`@event fn`, `on:change="picked"`).
- Shared stores: `stores/Name.gshtml` and `@use`, optionally kept in `localStorage`.
- Client navigation: `<body gw-boost>`.
- Transitions: `gw-enter` and `gw-leave`.
- Server push, client half: `gw-sse="/events"`, and `web::sse_event`, `web::sse_fragment`, `web::sse_store`.
- Warnings: `gen`, `build`, `start` and `test` take `--strict` and `--diagnostics json`. New codes: `unkeyed-for`, `unknown-attribute`, `unknown-event`, `child-key`, `prop-keyword`, `state-keyword`, `computed-keyword`, `computed-no-state`, `watch-no-state`, `state-unused`. `gweb dev` shows warnings in a corner box.
- Runtime split: `gwi.js` is the 4 KB core. Fragments and each other feature are optional modules (`gwf`, `gwh`, `gwl`, `gwm`, `gwc`, `gwn`, `gws`, `gwt`, `gwe`), served only to sites that use them. Fragment pages now load `gwf.js` and `gwi.js`.
- Changed: a component root with a text part gets `<!--g-->` markers in its HTML.

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
