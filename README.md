# goose-web

A Next.js-like web framework for [Goose](https://aardappel.github.io/goose/), on
[goose-net](../goose-net). Folders under `app/` are routes. `gweb` turns the
project into one native binary that serves on every core.

```
gweb new mysite && cd mysite
GOOSE=/path/to/goose gweb dev          # rebuilds and restarts on every change
```

The design is in [DESIGN.md](DESIGN.md). [DESIGN-ADDENDUM-1.md](DESIGN-ADDENDUM-1.md)
replaces its handler API (section 4). [DESIGN-ADDENDUM-2.md](DESIGN-ADDENDUM-2.md)
sets the worker default, the accept rules and SQLite. All came from the
goose-architect agent.

## Project layout

| File | Meaning |
|---|---|
| `app/**/route.goose` | API endpoint: `fn GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS` |
| `app/**/page.html` | Server-rendered page (template) |
| `app/**/page.goose` | Optional: `Props`, `fn load`, helpers for the page beside it |
| `app/**/layout.html` | Wraps every page at or below its folder; `{{slot}}` marks the page |
| `app/**/middleware.goose` | `fn before` and/or `fn after` for the subtree |
| `app/not-found.html` | The 404 page, inside the root layout |
| `app/state.goose` | State owned by the main thread: `Msg`, `Reply`, `fn handle`, optional `fn init` |
| `lib/**.goose` | Your modules: `import lib.catalog;` (write their `namespace`) |
| `public/**` | Static files, embedded in the binary, with ETags |

A folder named `[id]` is a dynamic segment. Folders starting with `_` are
ignored. App files get their namespace from `gweb`; do not write one.

## Signatures

```goose
fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&)        // route.goose
fn load(req: const http::Request&, ctx: web::Ctx&) -> Props                      // page.goose
fn before(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) -> bool   // false: res is final
fn after(req: const http::Request&, ctx: web::Ctx&, res: http::Response&)
fn handle(msg: const Msg&) -> Reply                                               // state.goose
```

Helpers: `web::param(ctx, "id")`, `web::param_int`, `web::query(req, "q", out)`,
`web::html(res, status)`, `web::json(res, status)`, `web::not_found(ctx)`,
`web::redirect(ctx, "/to", 302)`, and `state::ask(ctx, state::Msg.List) -> Reply, bool`.
Set `ctx.title` in `load`; layouts read it.

## Templates

| Syntax | Does |
|---|---|
| `{{ expr }}` | writes the value, HTML-escaped |
| `{{{ expr }}}` | writes it raw |
| `{{#if e}}` `{{#else if e}}` `{{#else}}` `{{/if}}` | conditions |
| `{{#for x in e}}`, `{{#for x, i in e}}`, `{{/for}}` | loops |
| `{{#let n = e}}` | a local |
| `{{> f(a)}}` | calls `f(out, a)` |
| `{{slot}}` | the page, in a layout |
| `{{-- note --}}` | a comment |

Expressions are Goose. In scope: `req`, `ctx`, `props` (when `load` exists)
and everything `page.goose` imports. A tag stays on one line, and each HTML
line compiles to one Goose line, so compiler errors point at the HTML line.

## Commands

```
gweb [-C dir] new <dir>      a starter project
gweb gen                     write .gooseweb/ only
gweb build [--debug]         gen, then goose build to .gooseweb/server
gweb start [flags]           build and run (--port N --workers N --log --idle-ms N --max-body N)
gweb dev [flags]             build, run with --log on 2 workers, rebuild on change
gweb routes                  the route table
gweb test                    component parity: test_* functions as Goose and as JavaScript
```

`gweb` finds the compiler in `$GOOSE`, else `goose` on `PATH`, and finds this
package beside its own binary (or `$GOOSE_WEB_HOME`). Build `gweb` with:

```
goose build -o gweb cli/gweb.goose
```

## How it runs

- The default is min(performance cores, 4) workers; `--workers N` or
  `WEB_WORKERS` override it. On the test Mac, more workers only helped
  routes that do real work.
- One listening socket; each worker thread runs its own goose-net poll loop.
  With several workers each takes one new connection per wake, so bursts
  spread; one worker takes all that wait. After 16 requests the loop polls
  once without waiting, so new clients are accepted under load.
- macOS caps the listen backlog at 128. For many simultaneous clients you can
  raise it: `sudo sysctl -w kern.ipc.somaxconn=1024` (optional).
- Each worker runs under a supervisor that restarts it after an abort.
- `app/state.goose` lives on the main thread. Workers reach it over one
  socketpair each (`src/owner.c`), with a 5 s reply timeout.
- Pages render on every request into one buffer; static files go out from
  the binary's data with `writev`, without a copy.

## SQLite

Apps can read SQLite through the sibling package
[goose-sqlite](../goose-sqlite): write `import sqlite;` in a `lib/` or `app/`
file, and `gweb` declares the package. Each worker opens its own read-only
connection with `sqlite::local(path)`. See `examples/shop/lib/shopdb.goose`.

## Cookies

Read cookies from `req`, set them through `ctx`. Setting works the same in a
route handler, a page loader and middleware, and every accepted cookie is sent
whatever the outcome (200, redirect, not found, or a `before` that returned
false). `run_worker` moves the pending `Set-Cookie` lines into `res.headers`
after the dispatcher returns.

```goose
let theme = web::cookie_or(req, "theme", "light");          // one raw value, for layouts and templates
let n, ok = web::cookie_int(req, "visits");                 // i64, bool
var v: u8[>..] = [];
let has = web::cookie(req, "name", v);                      // percent-decoded, appended to v

web::set_cookie(ctx, "seen", "1");                          // session cookie, HttpOnly, SameSite=Lax
web::set_cookie(ctx, "theme", "dark", web::CookieOptions { max_age: 31536000, http_only: false, .. });
web::clear_cookie(ctx, "theme");                            // pass the same path and domain it was set with
```

A layout can read a cookie without a loader: `<body class="{{ web::cookie_or(req, "theme", "light") }}">`.

`CookieOptions` has `path` (`/`), `domain` (none, this host only), `max_age`
(-1: until the browser closes), `secure` (false), `http_only` (true) and
`same_site` (`SameSite.Lax`, `Strict` or `None`). `SameSite.None` always writes
`Secure`. `secure` defaults to false because goose-web serves plain HTTP; set it
when the site is behind TLS.

`set_cookie` returns false and sets nothing when the name is not an RFC 6265
token of 1 to 64 bytes, the path or domain is bad, `max_age` is below -1, a
`__Secure-` or `__Host-` prefix rule is broken, or the encoded value is over
1024 bytes. Check the result for values that come from users: Goose does not
warn about an ignored `bool`. Every byte of the value outside `A-Z a-z 0-9 - . _ ~`
is written as `%XX`, so a value that needed encoding reads back encoded through
`cookie_or` and `cookie_int`; use `web::cookie(req, name, out)` for those.

All `Set-Cookie` lines of one response share 2048 bytes. When they do not fit
beside the headers already in `res`, the reply becomes a bare
`500 {"error":"response headers too large"}`; a cookie is never dropped silently.
Pages that set cookies carry no `Cache-Control`; behind a shared cache, set
`Cache-Control: no-store` in `after` middleware. Signed sessions are not in v1.
The demo is `examples/shop/app/cookies` (`/cookies`).

## Example

`examples/shop` is the benchmark site: pages, a JSON API, a todo list in
owner state, static files, and SQLite twins of the product routes under `/db`. Its Next.js twin is in
`../goose-bench/next-shop`.

## IMPLEMENTATION-NOTES: components

Components are parts of a page that run in the browser, written in a subset of
Goose (DESIGN-ADDENDUM-3, E1-E8 and follow-up 1).

**File shape.** `components/Name.gshtml` at the project root (flat; `Name` is
`[A-Z][A-Za-z0-9]*`). Line 1 is exactly `<script goose>`; a line that is
exactly `</script>` ends the script; the markup follows and refers to the
state as `s`.

```
<script goose>
struct State { count: i64 }
fn inc(s: State&) { s.count += 1; }
fn test_basic(s: State&) { inc(s); inc(s); }
</script>
<button on:click="inc">Clicked {{ s.count }} times</button>
```

- The script needs `struct State`. Types: `i64`, `bool`, `u8[..N]`, structs
  of the block, and one `Name[>..<]` as the last field of `State`.
- A handler is a function whose first parameter is `s: State&`. Markup calls
  it with `on:click`, `on:change`, `on:input` or `on:submit`:
  `on:click="remove(t.id)"`; arguments are `i64`, `bool` or strings.
- `bind:value="field"` and `bind:checked="field"` tie an input to a direct
  `State` field.
- Templates work as in `page.html` (`{{ }}`, `{{{ }}}`, `{{#if}}`, `{{#for}}`,
  `{{#let}}`), except `{{component}}`, `{{slot}}` and `{{> f()}}`.
- The client subset (E3) leaves out `match`, `enum`, floats, `loop`, `guard`,
  `defer`, blocks, closures, slices, `as`, bitwise operators, char literals,
  generics, globals and imports. Callable: the block's functions, `min`, `max`,
  `abs`, `str`, `web::has`, `push`, `remove_at`, `clear`, `append`, and `.len`.
  gweb reports anything else at its line, as `components/Name.gshtml:LINE: error:`.

**Embedding.** `{{component Name(expr)}}` in any page, layout or not-found
template; `expr` is a `Name::State`, usually from `load`. Every template
imports every component, so `page.goose` can write `import Name;` and use
`Name::State` in its `Props`. The page gets the server render, the state as
JSON and `<script type="module" src="/_gw/Name.js">`.

**Output.** `.gooseweb/Name.goose` keeps the source's lines (compiler errors
point at the `.gshtml`), then `gw_check`, `gw_json` and `component`.
`.gooseweb/_gw/Name.js` is the browser module: pretty under `gweb dev` (real
names, a `// components/Name.gshtml:LINE` comment above each function), compact
under `gweb build` and `gweb start`. The runtime is `client/gwi.js` in dev and
`client/gwi.min.js` otherwise; both are served at `/_gw/` with ETags.

**`gweb test`.** Runs each component's `test_*` functions (each takes only
`s: State&`), plus a `zero` case, as Goose and as JavaScript, pretty and
compact, and compares the state and the render byte for byte. Needs `node`.
goose-web's own suite is `test/components.sh` (parity components in
`test/components/*.gshtml`, one `Fail*.gshtml` per error message, and a check that
`client/gwi.min.js` is current).

**Maintainers.** After editing `client/gwi.js`, run `client/build.sh` (esbuild
0.28.2 through `npx`, or `ESBUILD=/path/to/esbuild`); it writes
`client/gwi.min.js` with the source's FNV-1a hash in its banner.

**Limits (v1).** No keys in the DOM morph, so removing a list item reuses the
nodes after it. Integers above 2^53 lose precision in the browser. Component
state lives in the page only. Handlers get no event data.

