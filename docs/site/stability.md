# Stability and versions

This page is the 1.0 contract. A name or behaviour listed here as stable does not break before 2.0.

## Versions

gweb, goose-net and goose-sqlite release together with one version. `gweb` pins that tag of the other two.
This holds through 1.x. Each release names the Goose compiler version it was tested with.

- Breaking changes come only in a major release.
- A feature is deprecated in a minor release, with a `gweb` warning. It is removed no sooner than the next major.
- Every break is a CHANGELOG line that starts with `Breaking:` and says how to migrate. A major release ships a
  `tools/migrate-vN.sh` for what a script can do (`tools/migrate-v1.sh` for 1.0).
- Security fixes go to the latest minor, and, after 1.0, to the last minor of the previous major for six months.
- Before 1.0, a minor release (`0.x.0`) could break; a patch never did.

## Stable

### Project layout and special files

Under the project root:

| Path | Stable meaning |
|---|---|
| `app/**/route.goose`, `page.html`, `page.goose`, `layout.html`, `middleware.goose` | routes, pages, layouts, middleware |
| `app/not-found.html`, `app/**/error.html`, `app/**/loading.html` | the 404 page, error pages, the slow-fragment state |
| `app/state.goose`, `app/jobs.goose`, `app/config.goose`, `app/sitemap.goose`, `app/socket.goose` | state owner, jobs, startup check, sitemap and robots, WebSockets |
| `components/`, `stores/<Name>.gshtml`, `views/<group>/<Name>.goose` and `.html`, `locales/default`, `locales/<tag>.txt` | components, client stores, views, message catalogs |
| `lib/**.goose`, `public/**`, `tests/*.goose` | your modules, static files, route tests |
| `gweb.packages` (project), `gweb.package` (package) | package list, with `package NAME SOURCE` lines for Goose packages (1.1); a package's `name` and `gweb` minimum |

The filenames are exact: `jobs.goose`, `config.goose`, `socket.goose`, `sitemap.goose`, `error.html`, `loading.html`,
`not-found.html`. Folders named `[id]`, `[...slug]`, `[[...slug]]` are dynamic segments and catch-alls; folders that
start with `_` are ignored. `gweb.package` is `name IDENT` and `gweb VERSION`, where `gweb 1.0` accepts any 1.x.

### Hooks: the functions gweb calls in your code

Names, parameter types and result types are stable. Every hook is optional unless its file says otherwise.

```goose
// route.goose
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&)     // also POST PUT PATCH DELETE HEAD OPTIONS
// page.goose
fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props
fn POST(req: const http::Request&, ctx: gweb::Ctx&) -> Props                 // or with res: http::Response& added
fn static_paths() -> u8[..1024][>..]
// middleware.goose
fn before(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) -> bool
fn after(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&)
// state.goose
fn init()
fn handle(msg: const Msg&) -> Reply                                          // const Msg..& with VARIABLE_MSG
fn shutdown()
// jobs.goose
fn run(job: const Job&, ctx: gweb::Ctx&) -> bool
fn schedule(s: gweb::Schedules&)
// config.goose
fn check() -> bool
// sitemap.goose
fn entries(req: const http::Request&, ctx: gweb::Ctx&, s: gweb::Sitemap&)
fn robots(req: const http::Request&, ctx: gweb::Ctx&, out: u8[>..]&)
// socket.goose
fn open(ctx: gweb::Ctx&, id: u64, topic: const u8[:])
fn message(ctx: gweb::Ctx&, id: u64, topic: const u8[:], data: const u8[:], binary: bool)
fn close(ctx: gweb::Ctx&, id: u64, topic: const u8[:])
// views/<group>/<Name>.goose
fn validate(p: const Props&, errs: gweb::FieldErrors&)
```

Also stable: `const VARIABLE_MSG`, the `Props`, `Msg`, `Reply` and `Job` names, `ctx.title`, `ctx.route` and the other
`Ctx` fields the README names.

### Public module paths

These import paths are stable, with the documented names inside them:

`gweb` (the root), `gweb.testing`, `gweb.auth.session`, `gweb.auth.csrf`, `gweb.auth.cors`, `gweb.auth.rate`,
`gweb.auth.crypto`, `gweb.forms.form`, `gweb.forms.valid`, `gweb.forms.upload`, `gweb.http.files`, `gweb.http.stream`,
`gweb.http.push`, `gweb.http.cache`, `gweb.http.static`, `gweb.ops.log`, `gweb.ops.jobs`, `gweb.site.markdown`,
`gweb.site.meta`, `gweb.site.sitemap`, `gweb.site.i18n`, `gweb.site.errors`, `gweb.site.views`, `gweb.site.template`.
Their files are in the folders of the same names. The generated `t::` (messages) and `views` modules, and a mounted
package's `NAME::MOUNT` constant, are stable too.

### Documented `gweb::` names

A `gweb::` function, type or constant is stable if the README, a page under `docs/site/` or a
`DESIGN-ADDENDUM` documents it, or if it is in the Signatures block. That covers `Ctx`, `Config`, `Level`,
`FieldErrors`, `FileOptions`, `Schedules`, `Sitemap`, `ErrorInfo`, `ViewMeta` and `FieldUi`, and the functions named
in the README sections (cookies, CSRF, sessions, rate limits, CORS, forms, uploads, files, streaming, push, logging
and metrics, i18n, Markdown, cache, jobs, tests). Names in the Limits table keep their stated defaults. A limit may
grow; it never shrinks.

**Not stable:** a name the docs do not mention, and every name that begins with `_` (see Internal names). They may be
renamed, re-typed or removed in any release.

### Template and `.gshtml` syntax

The template tags in the README Templates table (`{expr}`, `{#raw}`, `{#if}`, `{#for}`, `{#let}`, `@f()`, `@Name()`,
`@slot()`, `{-- --}`), the literal-brace and `@` rules, the component syntax, and the client subset of `.gshtml`
(it may grow, not shrink). `gw-target`, `gw-key`, `gw-loading`, the `GW-Fragment` request header, and the
`gw_read`, `gw_write`, `gw_field` and `gw_parse` conventions in views, `ITEM_LABEL`, and the generated `g_form_req` and `.act` button names (1.1).

### Commands, flags and environment

- The commands `new`, `gen`, `build`, `start`, `dev`, `export`, `routes`, `test`, `check`, `lsp`, `version` and
  `help`, with `-C dir`, `--strict`, `--diagnostics json`, `--no-minify`, `--debug` and `-o DIR`.
- Server flags and their `GWEB_*` variables: `GWEB_PORT` (and its alias `PORT`), `GWEB_HOST`, `GWEB_WORKERS`,
  `GWEB_ACCESS_LOG`, `GWEB_IDLE_MS`, `GWEB_MAX_BODY`, `GWEB_MAX_UPLOAD`, `GWEB_MAX_UPLOAD_PARTS`,
  `GWEB_MAX_UPLOAD_FILES`, `GWEB_MAX_UPLOAD_TEXT`, `GWEB_UPLOAD_DIR`, `GWEB_CSP`, `GWEB_TRUST_PROXY`,
  `GWEB_SECURITY_HEADERS`, `GWEB_HSTS`, `GWEB_SESSION_IDLE`, `GWEB_SESSION_MAX`, `GWEB_LOG_FORMAT`, `GWEB_LOG_LEVEL`,
  `GWEB_METRICS`, `GWEB_DRAIN_MS`, `GWEB_DRAIN_DELAY_MS`, `GWEB_JOB_RUNNERS`, `GWEB_JOB_QUEUE`, `GWEB_JOB_ATTEMPTS`,
  `GWEB_SCHEDULE`, `GWEB_SECRET`, `GWEB_ENV`; for the tool: `GOOSE`, `GWEB_HOME`, `GWEB_SRC`, `GWEB_NET`,
  `GWEB_SQLITE`, `GWEB_REF`, `GWEB_PKG_<NAME>` (1.1); build-time `SITE_URL`.
- Precedence: flag, then environment (real, then `.env` files), then default. A bad value exits 2 and names its source.
- Exit status: 0 success, 1 a failed check or test, 2 a bad command line or config.
- `gweb dev` defaults to `127.0.0.1`, port 60053, 2 workers and the access log; flags and variables still win.
- The shape of messages (`path:line: error: msg`). The wording is not stable.

### URLs and cookies

- `/_gw/` (component runtime assets) and `/__gweb/` (`health`, `ready`, `metrics`, `id`) are reserved. A route or a
  public file may not use either prefix, and `gweb::reserved_prefixes()` lists them.
- Cookies: `gw_session` and `gw_csrf`, and their `__Host-` forms, which are used, with `Secure`, when the request is
  HTTPS (direct, or behind a proxy with `GWEB_TRUST_PROXY`). The `_csrf` form field.
- `X-Forwarded-Proto` counts only under `GWEB_TRUST_PROXY`.

## Internal names

Everything below is outside the contract.

- A `gweb::` name that begins with `_` is internal: `gweb::_respond`, `gweb::_new_ctx` and the like. The convention
  holds in every library file. Goose has no nested namespaces, so the `_` prefix is the marker, not a `gweb::rt`
  namespace. Calling one from app code is allowed and unsupported.
- A few names stay unprefixed because only generated code or templates call them: `put`, `raw`, `arg`, `has`,
  `json_text` and their kin. They were not renamed, they are not documented, and they may change. Do not call them.
- Everything in `.gweb*/` (`.gweb/`, `.gweb.dev/`, `.gweb.test/`, `.gweb.check/`, `.gweb.lsp/`, `.gweb.uploads/`):
  generated code, `map.txt`, spool files.
- `gweb lsp-gen`, `gweb test-css` and `gweb semver-cmp`.
- Message wording, the internals and size of `gwi.js` and its sibling scripts, performance numbers, and the exact text
  of the startup line.

## What the 1.0 break list did

`tools/migrate-v1.sh` renames the public names that moved (`gweb::write` to `gweb::stream_write`, `gweb::info` to
`gweb::log_info`, and so on), `.gooseweb*` to `.gweb*` and `--log` to `--access-log`. The CHANGELOG lists each
`Breaking:` line for 1.0.
