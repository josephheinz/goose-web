<!-- Produced by goose-architect on claude-fable-5-2 -->
# Replacement for decision 4 (and the template part of 7)

**Decision:** the request goes in its own `const` parameter, `Ctx` becomes fully flat, and loaders no longer receive `res`. Point 5 stands as you built it.

I checked this with `goose check`, then built and ran it inside a `thread_fn`: `/private/tmp/claude-501/-Users-joeheinz--claude-spares-spare-sGecwS/10d9fa68-9193-489c-9d6d-af48a0a097a1/scratchpad/alias3/C.goose`. It compiles and gives the expected output for eight requests, covering:
- a handler that shrinks `res` repeatedly between reads of `ctx` and `req`;
- middleware `before`/`after`;
- a loader whose `Props` holds slices into `req`, `ctx` and static data;
- a generic layout with the page as a trailing block;
- not-found, redirect, and the static-index return.

It uses a stand-in `Ctx` and helpers in the global namespace, not your `web.goose`, and calls the real goose-net (`send_response_with` included).

## Signatures

```goose
// route.goose
fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&)

// page.goose — no res
fn load(req: const http::Request&, ctx: web::Ctx&) -> Props

// middleware.goose
fn before(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) -> bool
fn after(req: const http::Request&, ctx: web::Ctx&, res: http::Response&)

// generated from page.html / layout.html
fn render<P>(out: u8[>..]&, req: const http::Request&, ctx: const web::Ctx&, props: const P&)
fn render<F>(out: u8[>..]&, req: const http::Request&, ctx: const web::Ctx&)      // layout, {{slot}} = F()

// generated dispatcher, and the worker
fn dispatch(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) -> i64   // static index or -1
fn run_worker<D, S>(slot: i64, server: net::Socket, owner_fd: i32, cfg: Config)
```

Template scope: `req`, `ctx`, `props` (only when `page.goose` has `load`), plus the page's namespace. Layouts and `not-found.html` get `req` and `ctx`.

## Ctx

```goose
enum Outcome { Continue, NotFound, Redirect }
struct Params { n: i64, names: u8[..32][8], values: u8[..256][8] }     // values are copies
struct Ctx {
    params: Params, worker: i64, owner_fd: i32,
    outcome: Outcome, redirect_status: i64, location: u8[..1024],
    title: u8[..256]
}
```

No references or slices anywhere, so the checker can never suspect it of pointing into `res`.

## How each thing works

- **Params:** `web::set_param(ctx, name, value) -> bool` copies the segment. It returns false when the value is over 256 bytes, the name is over 32, or there are already 8; the dispatcher treats false as no match (404). `web::param(ctx, "id") -> const u8[:]` is a view into `ctx`; `web::param_int(ctx, "id") -> i64, bool`.
- **Query and headers:** from `req`. `http::query_param(req, "q")` and `http::header(req, "name")` as they are; `web::query(req, "q", out) -> bool` for the decoded value.
- **Title:** `ctx.title.append(...)` in `load`; layouts read `ctx.title`.
- **Not found:** `web::not_found(ctx)` sets the outcome only.
- **Redirect:** `web::redirect(ctx, to, status = 302)` stores the location in `ctx`; it no longer takes `res`.
- **Outcome is applied in one place:** a generated `finish(req, ctx, res)` runs after every route or page. It renders the not-found page or writes the status and `Location`. So `not_found` and `redirect` work the same in handlers, loaders and `before`.
- **State:** `state::ask(ctx, msg) -> Reply, bool` is unchanged; it only needs `ctx.owner_fd`.

## Generator rule this adds

For a page, call `web::html(res, Ok)` **before** `load`, and do not shrink `res` between `load` and `render`. `Props` may hold slices, so it gets the same treatment `Ctx` got. In the experiment the order is `before` → `html` → `load` → layout/page render → `after`, then `finish`.

## Why

Your experiments show the checker accepts a request passed straight through as `const http::Request&` but rejects any struct that carries it. Keeping `req` separate and making everything else flat is the only shape that passed, and copying params keeps `web::param(ctx, "id")` to two arguments.

## Rejected

- **Offsets into `req.path` (your variant A):** compiles, but every lookup becomes `web::param(req, ctx, "id")`.
- **A const `web::Req` wrapping the request plus params:** it is the same shape as your failing B.
- **Telling users to read `ctx` before touching `res`:** unenforceable, and `http::json_error` clears.
- **Loaders keeping `res`:** a `Props` with slices would then block `web::html` and any later shrink.

## Risks

- A path segment over 256 bytes is a 404 rather than a match.
- Loaders cannot set response headers or cookies; that needs `after` middleware or a route.
- `Ctx` is about 3.6 KB built per request. I expect that to be negligible but did not measure it.
- A title set by a loader that then calls `not_found` shows up on the 404 page (seen in the test output). `finish` should clear `ctx.title` before rendering not-found.
- A route handler that returns a body and also sets an outcome has its body discarded by `finish`.

## Point 5

It stands: `dispatch` returns the embedded-file index or -1, `S(index)` yields the bytes, and they go out through `http::send_response_with`. The experiment uses exactly that shape. The alternative, a `static_index` field in `Ctx`, buys nothing over the return value.
