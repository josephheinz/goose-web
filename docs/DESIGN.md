<!-- Produced by goose-architect on claude-fable-5-2 -->
# goose-web v1 design

## Summary

goose-web is a package (`web`, directory `goose-web`, sibling of `goose-net`) plus a CLI (`gweb`). `gweb` scans `app/`, `lib/`, `public/`, writes a generated program into `<project>/.gooseweb/`, and runs `goose build` on it. User files are **copied** into `.gooseweb/` under identifier names with a derived `namespace` prefixed onto line 1, so line numbers are unchanged and users write no namespace. Templates compile to one Goose line per HTML line. Workers share one listening fd, each running its own goose-net loop. The owner thread is `main`, reached over per-worker socketpairs.

I checked the core of this with `goose check`/`goose build` in the scratchpad (`e1/`, `e2/`, `e3/`). What compiled and ran:

- Line-1 namespace prefix, including `namespace r1; // comment` and `namespace r2; import std;`.
- Two files sharing one namespace (page code + its template).
- A generic layout taking the page as a trailing block.
- `thread_fn worker` calling `web::run_worker(..., dispatch)` with `dispatch` as a named-function generic argument.
- `fn state::ask` declared from `main.goose`.
- A non-flat `state` global used only from `main`, while workers call `state::ask`.
- Supervisor threads respawning contained workers.
- A hidden root directory, `embed_file` on a path with spaces and brackets, and `-o`.

Not tested: the real socketpair transport (I used a queue stand-in), accept balance, and anything in the CLI.

Findings that change the constraints you gave me:

- **Root directory is the import root.** With the root at `.gooseweb/main.goose`, imports are `import r1;`, not `import gen.r1;`, and `import lib.util;` needs `.gooseweb/lib`.
- **Package sources are compared as paths, not resolved.** The root must declare `net` at exactly `<goose-web dir>/../goose-net` (absolute is fine). Declaring the real path behind a symlink fails with "declared from a different source".
- **`var props: Props;` is illegal** ("must be constructed at its declaration"). Loaders must return the value. `Props { .. }` works without declared defaults.
- **A struct with a resizable tail cannot be an array element**, so it cannot go through `from_bytes<R[>..]>`. `Reply` must be fixed or variable-size (`Todo[]`, not `Todo[>..]`); the receiver needs `copy(r)`.
- **A variant literal passes to a by-value enum parameter.** `state::ask(ctx, state::Msg.Add { title: t })` compiles when `ask` takes `msg: Msg`, not `const Msg&`.
- **`--diagnostics json` exists** (`docs/command_line.md` §6), as does `goose build -o`.

## 1. App directory conventions

**Choice.**

| File | Meaning |
|---|---|
| `app/**/route.goose` | API endpoint: functions named `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS` |
| `app/**/page.html` | Server-rendered page |
| `app/**/page.goose` | Optional: `Props` type, `load`, helpers for the template beside it |
| `app/**/layout.html` | Wraps every page at or below its directory; nests outermost first |
| `app/**/middleware.goose` | `before` / optional `after` for the subtree |
| `app/not-found.html` | 404 page (root only), rendered inside the root layout |
| `app/state.goose` | Owner-thread state (root only) |
| `lib/**.goose` | Shared modules, `import lib.catalog;`; the user manages their namespaces |
| `public/**` | Static files |

- Dynamic segment: a folder literally named `[id]`; the name inside must be an identifier and becomes the param name.
- Folders starting with `_` are ignored.
- `route.goose` and `page.html` in the same folder is a gen error; so is a public file colliding with a route.
- Import mechanism: copy each `app/` file to `.gooseweb/<ns>.goose` with `namespace <ns>; ` prefixed to line 1; symlink `.gooseweb/lib -> ../lib`.

**Why.** Copies allow bracket and hyphen folder names and inject the namespace without shifting lines. Only column numbers on line 1 move.

**Rejected.**
- Symlink mirror: cannot inject a namespace, so every user file would need one.
- Identifier-only folders (`_id_`): not Next-like, and still needs namespaces.
- Inlining everything into one file: line mapping becomes a table instead of an identity.
- Catch-all `[...x]` and route groups `(x)`: deferred to v2.

**Risks.** Editors see route files without a namespace or a root, so the language server may flag `import web;`. A stale `.gooseweb/` is avoided by wiping it on every gen.

## 2. Namespaces

**Choice.** Derived and auto-inserted into the copy; a user file under `app/` containing a `namespace` line is a gen error.

- Names: `r<N>_<slug>` for routes, `p<N>_<slug>` for a page (shared by `page.goose` and its template), `l<N>` for layouts, `m<N>` for middleware, and fixed `state`.
- `N` is the index in sorted path order; the slug is for readable errors, e.g. `r3_api_todos_id`.

**Rejected.**
- Requiring users to write one: boilerplate, and collisions are silent.
- Editing the user's file in place: surprising.

**Risk.** Errors mention `r3_api_todos_id::GET`; the CLI appends the source path.

## 3. Generated code and dispatcher

**Choice.** Everything lives in `<project>/.gooseweb/`: `main.goose` (root), the copies, `*_html.goose` templates, the `lib` symlink, `map.txt` (gen file to source file, and `main.goose` line to source), and the binary `server`.

`main.goose` starts:

```goose
import std;
import web from "/abs/path/goose-web";
import net from "/abs/path/goose-web/../goose-net";   // must be this exact path form
import net.http;
```

`gweb` finds goose-web from `GOOSE_WEB_HOME`, else from its own `resource_dir()`.

Dispatcher:
- **Matching:** `web::split` cuts the path into at most 16 segment slices. Then `match n` on segment count; inside, nested `if` with literal segments tested before dynamic ones. Each leaf calls a generated `route_<N>(ctx, res)`.
- **Methods:** `route_<N>` matches on `ctx.req.method`. The CLI learns which methods exist by scanning for `^fn (GET|POST|...)\(`.
- **HEAD:** falls back to `GET` with the body dropped (`send_response` already has `head_only`).
- **OPTIONS:** without a handler, 204 with `Allow`.
- **405:** carries `Allow`.
- **Trailing slash:** `/x/` gets a 308 to `/x` for GET/HEAD, done in `run_worker` before dispatch.
- **Static files:** tried after routes, GET/HEAD only.
- **404:** generated `not_found(ctx, res)` renders `not-found.html` in the root layout, else plain text.

**Rejected.**
- Linear if-chain over full paths: fine for 20 routes, poor for 500.
- Compile-time generic route registration: no way to iterate registrations.
- Treating `/x/` as `/x`: duplicate URLs.

**Risks.** Segments are compared raw, so percent-encoded literal segments do not match. A handler with the wrong signature errors in `main.goose`; `map.txt` maps that line to the route file with the expected signature.

## 4. Handler API

**Choice.** Every user function takes `(ctx: web::Ctx&, res: http::Response&)`.

```goose
namespace web;
struct Params { n: i64, names: const u8[:][8], values: const u8[:][8] }
enum Outcome { Continue, NotFound, Done }
struct Ctx {
    req: http::Request, params: Params,
    worker: i64,            // 0..workers-1
    owner_fd: i32,          // -1 when there is no state.goose
    outcome: Outcome, title: u8[..256]
}
struct Config { port: i64, host: u8[..64], workers: i64, log: bool, idle_ms: i64, max_body: i64 }

fn param(ctx: const Ctx&, name: const u8[:]) -> const u8[:]          // raw, "" if absent
fn param_int(ctx: const Ctx&, name: const u8[:]) -> i64, bool
fn query(ctx: const Ctx&, name: const u8[:], out: u8[>..]&) -> bool   // URL-decoded
fn not_found(ctx: Ctx&)                                              // sets outcome
fn redirect(ctx: Ctx&, res: http::Response&, to: const u8[:], status: http::Status = http::Status.Found)
fn html(res: http::Response&, status: http::Status)
fn json(res: http::Response&, status: http::Status)
fn put(out: u8[>..]&, s: const u8[:])     // escaped; also put(out, i64), put<T>(out, const T&)
fn raw<T>(out: u8[>..]&, v: const T&)
fn run_worker<D>(slot: i64, server: net::Socket, owner_fd: i32, cfg: Config)   // D = dispatch
fn owner_loop<M, R, H>(chans: Channels)                                        // H = state::handle
fn owner_call<M, R>(ctx: Ctx&, msg: M) -> R, bool
```

User signatures:

```goose
fn GET(ctx: web::Ctx&, res: http::Response&)                 // route.goose
fn load(ctx: web::Ctx&, res: http::Response&) -> Props       // page.goose; the type may have any name
fn before(ctx: web::Ctx&, res: http::Response&) -> bool      // middleware.goose; false = response is final
fn after(ctx: web::Ctx&, res: http::Response&)               // optional
```

- A loader that calls `web::not_found(ctx)` or `web::redirect` returns `Props { .. }`; the dispatcher checks `ctx.outcome` and skips rendering.
- Middleware order: `before` outermost directory first, `after` in reverse; `after` is skipped if a `before` returned false.

**Rejected.**
- `Ctx` holding `res` by reference: reference-in-struct lifetime rules, for no gain.
- Loader out-parameter: illegal, see findings.
- Params as extra function arguments: variable arity complicates the generator.

**Risk.** Maximum 8 params and 16 segments; deeper paths get 404.

## 5. Multi-core model

**Choice.** One listening socket, with its fd passed to every worker; each worker runs its own `net::Loop`.

- Default workers: `hardware_threads()`; override with `--workers N` or `WEB_WORKERS`.
- Each worker runs under a generated `thread_fn supervisor` that loops on `thread_wait(thread_spawn_contained(worker, ...), why)`, logs the abort, and respawns. So a bounds error in a handler kills one worker, not the server.
- Logging: off in `start`, on in `dev`; one `print` per request.

**Why.** It works with goose-net today. I believe macOS does not balance `SO_REUSEPORT` listeners the way Linux does; that is from memory, not tested here.

**Rejected.**
- `SO_REUSEPORT` per worker: unbalanced on macOS; a Linux option later.
- Main accepts and hands fds to workers: exact balance, but needs fd-adoption in the loop; it is the fallback.

**Risks.**
- `accept_all` in `/Users/joeheinz/Documents/goose-net/src/loop.c` drains the whole backlog, so the first worker awake can take every connection of a burst. This needs the goose-net change in section 10.
- A respawned worker's old loop and its fds leak; clients on it hang until their timeout.
- The shared backlog is 128.

## 6. Owner-thread state

**Choice.**
- **Owner is `main`.** It may use non-flat globals, and the compiler rejects any handler that touches them directly.
- **Transport:** one `AF_UNIX SOCK_STREAM` socketpair per worker, created in `main` before spawning. Frames are a u32 length plus `to_bytes` of a one-element array. The owner `poll()`s all pairs in C and drains every ready request per wake. The worker blocks on its reply with a 5 s receive timeout.
- **User file** `app/state.goose`:

```goose
struct Todo { id: i64, title: u8[..200], done: bool }
enum Msg { List, Add { title: u8[..200] }, Get { id: i64 }, Remove { id: i64 } }
struct Reply { ok: bool, todos: Todo[] }          // fixed or variable-size; no resizable tail
var todos: Todo[>..<];
var next_id = 1;
fn init() { }                                      // optional, runs in main before workers start
fn handle(msg: const Msg&) -> Reply {
    match msg {
        List => { return Reply { ok: true, todos: todos[..] }; },
        ...
    }
}
```

- **Handler call:** `let reply, ok = state::ask(ctx, state::Msg.Add { title: t });`. `ok` is false on timeout or a bad frame; the handler answers 503.
- The names `Msg`, `Reply`, `handle` are required. `main.goose` generates `fn state::ask(ctx: web::Ctx&, msg: Msg) -> Reply, bool { return web::owner_call<Msg, Reply>(ctx, msg); }`.

**Rejected.**
- Typed queues both ways: replies cannot be addressed. My stand-in hit exactly this: the worker read its own request back.
- Queue in, C channel out: two mechanisms, and main could not poll.
- C mailbox with condvars: possibly faster; `ask` hides the transport, so it can replace the sockets later.
- Owner as a `thread_fn`: its state would have to be flat.

**Risks.** A worker blocked in `ask` stalls its other connections. All state traffic is serialized through one thread and about five syscalls per call.

## 7. Templates

> **Syntax changed (2026-11-12):** the tag spelling below is replaced by DESIGN-ADDENDUM-6-SYNTAX.md (`{expr}`, `{#raw expr}`, `@Name(expr)`, `@f(a)`, `@slot()`). The text stays as history.

**Choice.**

| Syntax | Compiles to |
|---|---|
| `{{ expr }}` | `web::put(out, expr);` — escapes `& < > " '` |
| `{{{ expr }}}` | `web::raw(out, expr);` |
| `{{#if e}}` `{{#else if e}}` `{{#else}}` `{{/if}}` | `if e {` ... `} else if e {` ... `}` |
| `{{#for x in e}}`, `{{#for x, i in e}}`, `{{/for}}` | `for x, i in e {` ... `}` |
| `{{#let n = e}}` | `let n = e;` |
| `{{> f(a, b)}}` | `f(out, a, b);` — any Goose function whose first parameter is `out: u8[>..]&` |
| `{{slot}}` | `F();` (layouts only) |
| `{{-- text --}}` | nothing |

- Expressions are Goose, pasted verbatim. In scope: `props` (when `page.goose` has `load`), `ctx`, and everything in the page's namespace.
- Layouts see `ctx` only; pages set `ctx.title` in `load`.
- A layout compiles to `fn render<F>(out: u8[>..]&, ctx: const web::Ctx&)`, so `{{slot}}` may sit inside an `{{#if}}`. A page compiles to `fn render<P>(out: u8[>..]&, ctx: const web::Ctx&, props: const P&)`.
- **Error mapping:** a tag may not span lines, and each HTML line becomes exactly one Goose line. The function header shares line 1 and the closing brace shares the last line. So `.gooseweb/p2_products_html.goose:N` is `app/products/page.html:N`; I confirmed the compiler reports the right line for a bad field. Unbalanced tags are `gweb` errors in the same `path:line: error:` form.

**Rejected.**
- JSX-like components: a parser project.
- Partial template files: `{{> f()}}` plus a Goose function covers v1.
- Whitespace trimming: breaks the line identity.
- Layout as open/close function halves: breaks a slot inside control flow.

**Risk.** Type errors inside generic `render` carry "instantiated from" lines pointing at `main.goose`.

## 8. Static files

**Choice.** Embedded: `let S3 = embed_file("../public/css/site.css");` in `main.goose`.

- Lookup is `match path.len`, then slice compares.
- Headers: `Content-Type` from the extension, a strong `ETag` (FNV-1a 64 of the content, computed by `gweb`), `If-None-Match` answered with 304, and `Cache-Control: public, max-age=0, must-revalidate`.
- `public/index.html` is not special. Dev mode uses the same path.

**Rejected.**
- Serving from disk: a second code path, slower.
- Long `max-age`: needs fingerprinted names.
- Precompressed variants: v2.

**Risks.** Large `public/` trees inflate the binary and compile time. The body is copied twice until the goose-net change below.

## 9. CLI

**Choice.** `gweb`, a Goose program in `goose-web/cli/` with its own sidecar. `cli/proc.c` supplies spawn-with-captured-output, wait, kill, mtime, symlink, mkdir and remove-tree.

| Command | Does |
|---|---|
| `gweb new <dir>` | Scaffold |
| `gweb gen` | Write `.gooseweb/` only |
| `gweb build [--debug] [-o path]` | gen + `goose build -o .gooseweb/server` |
| `gweb start [--port N] [--workers N]` | build + run |
| `gweb dev` | Watch loop |
| `gweb routes` | Print the route table |

- **Dev:** poll file count and newest mtime of `app/`, `lib/`, `public/` every 250 ms. On change, gen and build to `server.next`. On success, SIGTERM the child, rename, and respawn with `--log --workers 2`. On failure, print errors and keep the old server running.
- **Errors:** run `goose` with `--color never`, capture stderr, replace `.gooseweb/<file>:` using `map.txt` (and `.gooseweb/lib/` with `lib/`); line numbers pass through.
- The compiler is `$GOOSE`, else `goose` on `PATH`.

**Rejected.**
- Shell or Node CLI: an extra runtime.
- kqueue/FSEvents: not portable.
- `--diagnostics json`: more robust but needs a JSON pass; plain rewriting is enough for unique gen names.
- Browser live reload: v2.

**Risk.** The port is briefly closed on restart.

## 10. Layout and goose-net changes

```
goose-web/
  web.goose        Ctx, Params, Config, helpers, run_worker
  template.goose   put, raw, escape           (import web.template;)
  owner.goose      Channels, owner_loop, owner_call
  static.goose     send_static, mime types
  web.build        c_sources = ["src/owner.c"]; exclude = ["examples", "test"];
  src/owner.c      socketpairs, framed send/recv, owner poll
  cli/gweb.goose, cli/gweb.build, cli/proc.c, cli/scan.goose, cli/gen.goose, cli/tmpl.goose
  examples/shop/   the benchmark site
  test/
```

`web.goose` imports `net` by name; the root file declares where it comes from.

goose-net changes:
1. **Loop accept limit (required):** `connection_loop(server, idle_ms, max_request, accept_max = 0)`; goose-web passes 1 so each worker takes one connection per poll pass.
2. **Statuses:** `SeeOther` 303, `TemporaryRedirect` 307, `PermanentRedirect` 308 (308 currently prints "Unknown").
3. **`send_response` with an external body slice** (two-part send), so static files and rendered pages are not copied into a second buffer.

## Example

```
shop/
  app/layout.html
  app/page.html
  app/products/page.goose  page.html
  app/products/[id]/page.goose  page.html
  app/api/todos/route.goose
  app/api/todos/[id]/route.goose
  app/state.goose
  lib/catalog.goose
  public/css/site.css
```

```goose
// app/api/todos/[id]/route.goose
import std; import net.http; import web; import json;
fn GET(ctx: web::Ctx&, res: http::Response&) {
    let id, ok = web::param_int(ctx, "id");
    if !ok { http::json_error(res, http::Status.BadRequest, "id must be an integer"); return; }
    let reply, sent = state::ask(ctx, state::Msg.Get { id: id });
    if !sent { http::json_error(res, http::Status.ServiceUnavailable, "state unavailable"); return; }
    if !reply.ok { http::json_error(res, http::Status.NotFound, "todo not found"); return; }
    web::json(res, http::Status.Ok);
    for t in reply.todos { write_todo(res.body, t); }
}
```

```goose
// app/products/page.goose
import std; import net.http; import web; import lib.catalog;
struct Props { count: i64 }
fn load(ctx: web::Ctx&, res: http::Response&) -> Props {
    ctx.title.append("Products");
    return Props { count: catalog::ITEMS.len };
}
```

```html
<!-- app/products/page.html -->
<h1>{{ props.count }} products</h1>
<ul>
{{#for p in catalog::ITEMS}}
  <li><a href="/products/{{ p.id }}">{{ p.name }}</a> {{> price(p.cents)}}</li>
{{/for}}
</ul>
```

```goose
// .gooseweb/main.goose (sketch)
import r3_api_todos_id; import p2_products; import p2_products_html; import l0; import state;
let S0 = embed_file("../public/css/site.css");
fn state::ask(ctx: web::Ctx&, msg: Msg) -> Reply, bool { return web::owner_call<Msg, Reply>(ctx, msg); }

fn route_3(ctx: web::Ctx&, res: http::Response&) {            // app/api/todos/[id]/route.goose
    match ctx.req.method {
        Get, Head => r3_api_todos_id::GET(ctx, res),          // app/api/todos/[id]/route.goose: GET
        Options => web::options(res, "GET, HEAD, OPTIONS"),
        _ => web::method_not_allowed(res, "GET, HEAD, OPTIONS"),
    }
}
fn page_2(ctx: web::Ctx&, res: http::Response&) {
    let props = p2_products::load(ctx, res);
    if ctx.outcome != web::Outcome.Continue { if ctx.outcome == web::Outcome.NotFound { not_found(ctx, res); } return; }
    web::html(res, http::Status.Ok);
    l0::render(res.body, ctx) { p2_products::render(res.body, ctx, props); };
}
fn dispatch(ctx: web::Ctx&, res: http::Response&) {
    var seg: const u8[:][16] = [""; 16];
    let n = web::split(ctx.req.path, seg);
    match n {
        1 => { if seg[0] == "products" { page_2(ctx, res); return; } },
        3 => { if seg[0] == "api" && seg[1] == "todos" { web::set_param(ctx, "id", seg[2]); route_3(ctx, res); return; } },
        _ => {},
    }
    if static_file(ctx, res) { return; }
    not_found(ctx, res);
}
thread_fn worker(slot: i64, server: net::Socket, owner_fd: i32, cfg: web::Config) { web::run_worker(slot, server, owner_fd, cfg, dispatch); }
thread_fn supervisor(slot: i64, server: net::Socket, owner_fd: i32, cfg: web::Config) { /* respawn loop */ }
fn main() {
    let cfg = web::config_from_args();
    let server = net::listen(cfg.port, cfg.host);
    state::init();
    let chans = web::owner_channels(cfg.workers);
    for i in cfg.workers { thread_spawn(supervisor, i, server, web::worker_end(chans, i), cfg); }
    web::owner_loop<state::Msg, state::Reply>(chans, state::handle);
}
```

The comparison of `ctx.outcome` against a variant, and `seg` as a fixed array of slices filled by `split`, are sketch-level; I tested the surrounding shapes but not those two exact lines.

## 11. Benchmark sites

**Choice.** One "shop" site built twice from a shared `data/products.json` (100 products). A script generates `lib/catalog.goose` as a static `let` table; Next imports the JSON.

- **Pages:** `/` (layout + 8 featured), `/products` (all 100, about 25 KB), `/products/[id]` (404 for unknown), `/about` (no data), `/todos` (rendered from shared state).
- **API:** `/api/health`, `/api/products`, `/api/products/[id]`, `/api/todos` (GET, POST), `/api/todos/[id]` (GET, PUT, DELETE).
- **Static:** `/css/site.css` (about 5 KB), `/img/logo.svg`, `/js/app.js` (about 100 KB).
- No middleware on either side.

**Next.js.** App Router, server components only, the current stable `next` at install time with the exact version pinned and recorded (I did not check which major is current), Node 24.19. Run `next build && next start` with `compress: false` and `poweredByHeader: false`.

**Fairness.**
- **Rendering:** Next pages are measured twice. "Dynamic" uses `export const dynamic = "force-dynamic"`, matching goose-web's per-request rendering. "Static" uses Next's default prerendering with `generateStaticParams`, its best case. Report both.
- **Cores:** tier 1 is one goose-web worker vs one `next start`. Tier 2 is 4 workers vs 4 Next processes behind a `node:cluster` wrapper. Tier 3 is both as shipped (goose-web all cores, Next single process), labelled as a defaults comparison.
- **State:** todo scenarios for Next run in tier 1 only, since per-process state diverges under cluster.
- **Gate:** one `check_site.sh` asserting statuses and key substrings must pass on both; record response bytes per URL.

**Measure.** With `/Users/joeheinz/Documents/goose-bench/loadgen/loadgen.goose`, keep-alive at 1, 16, 64, 256 clients, median of 3, 5,000-request warm-up, and enough requests that each run lasts over 2 s. One close-mode run at 64 clients on `/`. Report req/s, p50/p99, errors, non-2xx, server CPU per 10k requests, RSS, time to first 200, and deploy size.

**Rejected.**
- `next dev`: not production.
- Only static Next or only dynamic Next: each alone is misleading.
- `ab`: fails on full backlogs here, per the existing `loadtest.sh` note.

**Risks.**
- loadgen uses a thread per client on the same 18-core machine and may cap the multi-core numbers. Measure its ceiling against a goose-net hello server first.
- A cluster wrapper is not identical to `next start`.
- Next HTML carries extra framework payload, so bytes differ.

## Build order

1. goose-net: accept limit, statuses, two-part send; keep the 92 checks green.
2. `web.goose`: `Ctx`, params, helpers, `run_worker` (single worker, hand-written `dispatch`).
3. `gweb gen` for `route.goose` only (scan, copy with prefix, `map.txt`, dispatcher) and `gweb build` with error rewriting.
4. Workers, supervisors, config flags.
5. Static files.
6. Templates: `tmpl.goose`, layouts, `page.goose`, `not-found.html`.
7. Middleware.
8. `owner.c`, `owner.goose`, `state.goose` generation.
9. `gweb dev`, `new`, `routes`.
10. Shop example, Next twin, `check_site.sh`, benchmarks.

## Open questions

1. **Accept balance on the shared fd.** Log connections per worker at 64 and 256 clients with `accept_max = 1`. If the spread is worse than about 2x, switch to main-accepts-and-hands-off.
2. **Owner round-trip cost.** Benchmark `/api/todos` at 1 and 8 workers. If it tops out well below the stateless routes, replace the socketpairs with a condvar mailbox behind the same `ask`.
3. **Default worker count on mixed cores.** `sysctl` reports 6 + 12 here. Run `/api/health` at 6, 12 and 18 workers to see whether `hardware_threads()` is the right default.
4. **Dead-worker cleanup.** Abort a handler under load and check whether its clients hang. If so, keep a per-slot loop handle in C and close it on respawn.
5. **Editor experience.** Open a route file with the Goose language server and see whether `import web;` without a root is flagged.

Files: scratch experiments are in `/private/tmp/claude-501/-Users-joeheinz--claude-spares-spare-sGecwS/10d9fa68-9193-489c-9d6d-af48a0a097a1/scratchpad/e1` (dispatch, templates, state), `e2/sup.goose` (supervisors) and `e3` (hidden root, `embed_file`). Code read: `/Users/joeheinz/Documents/goose-net/net.goose`, `http.goose`, `src/loop.c`, `/Users/joeheinz/Documents/goose-api/server.goose`, `/Users/joeheinz/Documents/goose-bench/results/SUMMARY.md`.
