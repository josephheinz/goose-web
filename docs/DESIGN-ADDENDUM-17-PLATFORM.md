<!-- Produced by goose-architect on claude-opus-5-5 (medium) -->
# goose-web decisions: data and platform (v0.3.0)

Scope, from `BACKLOG.md` "Platform": a query builder, Postgres support (designed only), i18n, and route test helpers that run a route in-process. Out of scope: WebSockets, background jobs (Addendum 16, operations), sitemaps, and everything owned by Addenda 12–16 and 18.

## What the decisions rest on

**Read:** `BACKLOG.md`, `ARCHITECTURE.md`, `DESIGN.md`, Addenda 1–11 (10 and 11 closely), `web.goose`, `owner.goose`, `template.goose`, `form.goose`, `csrf.goose`, `cli/gweb.goose` (gen, gen_main, gen_dispatch, test_cmd), `test/*.sh` and `test/*_test.goose`, `test/release_check.sh`, goose-sqlite (`sqlite.goose`, `src/sqlite.c`, `test/test_sqlite.goose`, README), goose-net (`http.goose`, `net.goose`). No sibling addendum (12–16, 18) existed when this was written.

**Facts the design uses:**
- **The worker path is a pure function of the request bytes.** `run_worker` parses with `http::parse_request(raw)`, makes `new_ctx(slot, owner_fd)`, calls the generated `dispatch(req, ctx, res)`, then `apply_cookies` and `dev_inject`. None of that needs a socket, so a test can run the same code on a byte buffer.
- **`fn state::ask` is defined from the generated `main.goose`** (DESIGN.md, verified). The same trick lets a generated test main define helpers that test files call.
- **A generic takes a named function as an argument** (`run_worker(..., dispatch, static_bytes)`, verified in DESIGN.md).
- **A struct with a resizable tail cannot be an array element** (DESIGN.md). Every struct here keeps at most one `u8[>..]`, as its last field, and none is put in an array.
- **Goose threads share no memory** (reference §22, CMS-STUDY): globals are copied when a thread spawns. In-process tests must therefore run on `main`, where `state` lives.
- **goose-sqlite already caches statements by SQL text** per connection. A builder that always binds values, and emits stable SQL text for one query shape, reuses that cache.
- **Reflection is contradictory in the studies.** CMS-STUDY built `fields<T>` over `u8[..120]` fields; GSHTML-STUDY says `fields<T>` rejects `u8[..200]`. Nothing here may depend on reflection.
- **Toolchain on this machine:** no `goose` on `PATH`, `$GOOSE` unset, and the SDK path in Addenda 10 and 11 (`/Users/joeheinz/...`) does not exist. Every Goose step below can be written but not compiled here. `node` and `python3` are present.
- **libpq 18.6 is installed** as a keg-only Homebrew formula (`/opt/homebrew/opt/libpq`, headers and `libpq.dylib` there, not on the default search paths). No Postgres server or `psql` is installed.

## Decision 1: a query builder in goose-sqlite, SQLite first

**Choice.** A new sub-module `query.goose` in goose-sqlite, `namespace sqlite;`, imported with `import sqlite.query;`. It builds SQL text with `?` placeholders and a list of bound values, and `sqlite::prepare(db, q)` prepares (through the existing cache) and binds them.

```goose
import sqlite.query;

var q = sqlite::select_from("todos", "id, title, done");
sqlite::where(q, "done", "=", false);
sqlite::where_raw(q, "title LIKE ?"); sqlite::arg(q, pattern);
sqlite::order_by(q, "id", true);
sqlite::limit(q, 20); sqlite::offset(q, 40);
let s = sqlite::prepare(db, q);
guard sqlite::ok(s) else { print(sqlite::query_error(q), sqlite::error(db)); return; }
while sqlite::step(s) { ... sqlite::int(s, 0) ... }

var u = sqlite::update_table("todos");
sqlite::set(u, "done", true);
sqlite::where(u, "id", "=", id);
let n, ok = sqlite::update(sqlite::prepare(db, u));
```

**The API** (UFCS lets `q.where(...)` read as a method):

```goose
enum Kind { Select, Insert, Update, Delete }
struct Query { ... }                                  // fields below; returned by value, passed by &

fn select_from(table: const u8[:], cols: const u8[:]) -> Query
fn insert_into(table: const u8[:]) -> Query
fn update_table(table: const u8[:]) -> Query
fn delete_from(table: const u8[:]) -> Query

fn where(q: Query&, col: const u8[:], op: const u8[:], v: i64)     // also f64, bool, const u8[:]
fn where_null(q: Query&, col: const u8[:])
fn where_not_null(q: Query&, col: const u8[:])
fn where_in(q: Query&, col: const u8[:], vs: const i64[:])         // also const u8[:][:]
fn where_raw(q: Query&, cond: const u8[:])                          // ? placeholders, filled by arg() in order
fn arg(q: Query&, v: i64)                                           // also f64, bool, const u8[:]; arg_null(q)
fn join(q: Query&, clause: const u8[:])                             // "JOIN users u ON u.id = t.user_id"
fn group_by(q: Query&, cols: const u8[:])
fn order_by(q: Query&, col: const u8[:], desc: bool = false)        // repeatable
fn limit(q: Query&, n: i64)
fn offset(q: Query&, n: i64)
fn set(q: Query&, col: const u8[:], v: i64)                         // also f64, bool, const u8[:]; set_null(q, col)
fn returning(q: Query&, cols: const u8[:])
fn all_rows(q: Query&)                                              // allow UPDATE or DELETE with no where

fn query_error(q: const Query&) -> const u8[:]                      // "" when the query is usable
fn sql_text(q: const Query&, out: u8[>..]&) -> bool                 // the SQL, for logs and tests
fn prepare(db: Db, q: const Query&) -> Stmt                         // failed Stmt when query_error != ""
```

**Rules:**
- **Values are always bound, never spliced.** `where`, `set`, `arg`, `where_in`, `limit` and `offset` all bind. `LIMIT ? OFFSET ?` is bound too, so paging keeps one SQL text.
- **Identifiers are checked.** `table` and `col` must match `[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?`. `op` must be one of `=`, `!=`, `<>`, `<`, `<=`, `>`, `>=`, `LIKE`, `GLOB`.
- **Raw text is checked.** `cols`, `where_raw`, `join`, `group_by` and `returning` refuse `'`, `"`, `;`, `--`, `/*` and a NUL byte, and only `where_raw` may hold `?`. String literals must therefore be bound, and a `?` is never inside a literal, so counting `?` is exact.
- **Misuse is an error value, not an abort.** The first misuse sets `q.error`; later calls do nothing; `prepare` returns a failed `Stmt`. Misuse covers: a bad identifier, operator or raw text; a `where_raw` whose `?` count is not met by `arg` calls before the next clause or `prepare`; more than 64 values; `set` on a SELECT or DELETE; `where` on an INSERT; UPDATE or DELETE with no `where` and no `all_rows`; INSERT or UPDATE with no `set`.
- **`where` clauses join with AND.** OR goes in a parenthesised `where_raw`.
- **`where_in` pads to a power of two** (1, 2, 4, …, 32) by repeating the last value, so the statement cache holds at most 6 texts per IN query. An empty list emits `0 = 1`. More than 32 values is an error.
- **`bool` binds as 0 or 1.**
- **Bind order:** `set` values, then `where` values in call order, then limit and offset. Calls may come in any order; the struct keeps a section tag per value.
- **The cache rule still holds:** two equal queries give the same `Stmt`, so do not run one while iterating the other.

**Struct layout** (only one growable field, last; no arrays of structs):

```goose
struct Query {
    kind: Kind, error: u8[..256], all: bool = false, pending: i64 = 0,
    table: u8[..64], cols: u8[..1024], sets: u8[..2048], joins: u8[..1024], wheres: u8[..2048],
    group: u8[..256], order: u8[..256], ret: u8[..256], lim: i64 = -1, off: i64 = 0,
    n: i64 = 0, section: i64[64], kinds: i64[64], ints: i64[64], floats: f64[64],
    text_at: i64[64], text_len: i64[64],
    texts: u8[>..]                                    // text values, back to back
}
```

A clause that does not fit its field is a misuse ("query too long"), never a truncation.

**Why goose-sqlite:** the binding half needs `Stmt` and `bind`, and goose-sqlite is the only database package. Putting the builder in goose-web would make the `web` package import `sqlite`, which gweb declares only when an app uses it (`uses_sqlite`). A dialect-neutral core with no driver import has nowhere to live until a second driver exists (Open question 1).

**Rejected:**
- A typed ORM over struct reflection (`select<Todo>()`): reflection over `u8[..N]` fields is unverified and contradicted (see evidence). Revisit once a compiler can test it.
- String-concatenating SQL helpers: they invite spliced values.
- Literal LIMIT/OFFSET: every page number would be a new cached statement.
- A dialect switch now: it would sit unused in a SQLite-only package.

## Decision 2: Postgres, designed and not built

The user allows edits only in the three repos, and a driver is naturally its own package, so nothing here is built. Where it lives is Open question 1. This is the design a builder should follow once that is settled.

**Package.** `goose-pg`, package `pg`, `namespace pg;`, layout like goose-sqlite: `pg.goose`, `src/pg.c`, `pg.build` (`c_sources = ["src/pg.c"]; c_libs = ["pq"];`), `test/test_pg.goose`, README, CHANGELOG. gweb gains an `import pg;` detection like `uses_sqlite` (a `uses_pg` flag in `scan_lib_for_sqlite`'s twin) and a `GWEB_PG` source override like `GWEB_SQLITE`.

**C layer: libpq, not the wire protocol in Goose.** libpq gives TLS, SCRAM-SHA-256 auth, `sslmode`, service files and every `PG*` environment variable. Goose has no TLS and no SHA-256 or HMAC in its stdlib (CMS-STUDY), so a pure-Goose client could not authenticate to a default Postgres 14+ server. The cost is a system dependency, as libsqlite3 already is.

**API, mirroring goose-sqlite so an app can switch with few edits:**

```goose
struct Db { h: u64 }
struct Stmt { h: u64 }
fn local(conninfo: const u8[:]) -> Db          // this thread's connection; "" = PG* environment variables
fn ok(db: Db) -> bool;  fn ok(s: Stmt) -> bool;  fn error(db: Db) -> u8[>..]
fn exec(db: Db, sql: const u8[:]) -> bool      // simple query protocol; may hold several statements
fn prepare(db: Db, sql: const u8[:]) -> Stmt   // $1, $2 ...; cached per connection by SQL text
fn bind(s: Stmt, i: i64, v: i64 | f64 | bool | const u8[:]) -> bool;  fn bind_null(s: Stmt, i: i64) -> bool
fn step(s: Stmt) -> bool                       // the first step executes; rows come from the held result
fn reset(s: Stmt)
fn int / float / text / text_len / is_null     // as goose-sqlite; columns parsed from text format
fn run(s) -> bool;  fn update(s) -> i64, bool  // PQcmdTuples
fn insert(s) -> i64, bool                      // needs "RETURNING id"; reads column 0 of the first row
fn begin(db) -> bool;  fn commit(db) -> bool;  fn rollback(db)
fn code(db: Db) -> u8[..5]                     // SQLSTATE of the last failure; "" when none
fn busy(db) -> bool                            // 40001, 40P01, 55P03, 57014
fn constraint(db) -> bool                      // class 23
fn migrate(db: Db, steps: const u8[:][:]) -> bool
```

- **Statements:** `PQprepare` with generated names `g1`, `g2`, … per connection, then `PQexecPrepared` with all parameters in text format and types left to the server. Results in text format. `bool` binds as `t`/`f`; `int` parses `t` and `f` too, so a boolean column reads as 0 or 1.
- **Results:** one `PGresult` per executed statement, held until `reset` or the end of rows. Large results are the app's problem in v1 (`LIMIT`); single-row mode is a follow-up.
- **Connections:** one per thread per conninfo, in a C thread-local list with the pthread-key destructor goose-sqlite already uses. With at most 4 workers plus the owner, a pool is not needed. A dead connection (`PQstatus` bad) is reset once with `PQreset` before a call fails.
- **Writes may run on workers.** Postgres has MVCC and row locks, so the owner-thread writer rule of Addendum 10 (which exists because SQLite has one writer lock) does not apply. An aborted worker's thread-exit destructor calls `PQfinish`, and the server rolls back its open transaction. The owner pattern stays available for writes that must be serialised in the process.
- **Migrations:** a table `goose_migrations (version integer)` with one row. `migrate` runs `BEGIN`, `SELECT pg_advisory_xact_lock(<fixed key>)`, reads the version, applies the missing steps, updates it and commits, so two server processes starting together do not both migrate.
- **Status mapping**, the app's own as in Addendum 10: `busy` 503, `constraint` 409, 0 rows 404, else 500.
- **Query builder:** the same API as Decision 1, rendering `$n` instead of `?`. The core moves to a shared place (Open question 1); until then `goose-pg` carries its own copy of `query.goose` with the renumbering, and both packages share one test file of SQL-text expectations.
- **Build flags:** Homebrew's libpq is keg-only. `pg.build` needs `/opt/homebrew/opt/libpq/include` and `/lib` on the compiler's search path. Whether `.build` files accept include and library paths is unverified; the fallback is documenting `CPATH` and `LIBRARY_PATH`.
- **Tests:** `test/test_pg.goose` reads `PG_TEST_URL`; with it unset, it prints "skipped: PG_TEST_URL is not set" and exits 0. Checks mirror `test_sqlite`: insert id via RETURNING, update counts, unique violation gives `constraint` and `23505`, rollback discards, a second connection's `SELECT ... FOR UPDATE NOWAIT` gives `busy`, migrate fresh/again/newer-refused/failure-rolls-back, and four threads writing in parallel with 0 failures.

**Rejected:** a pure-Goose wire client (no TLS, no SCRAM); one connection on the owner for everything (serialises every read); a pool (no shared memory between threads; per-thread connections are the pool).

## Decision 3: in-process route tests

**Choice.** A project may hold `tests/*.goose`. `gweb test` compiles them with the app's real dispatcher into one program and runs every `fn test_*(t: web::Tester&)` on `main`, after `state::init()`. Each test sends requests through the same code path the worker uses, minus the socket.

```goose
// tests/todos.goose
fn test_list(t: web::Tester&) {
    let res = site::get(t, "/api/todos");
    web::expect_status(t, res, 200);
    web::expect_contains(t, res.body, "\"title\"");
}

fn test_add(t: web::Tester&) {
    site::get(t, "/fragments");                                   // sets the CSRF cookie
    let res = site::post_form(t, "/fragments", "add=1&title=milk");
    web::expect_status(t, res, 200);
    web::expect_contains(t, site::get(t, "/fragments").body, "milk");
}
```

**Runtime, in goose-web:**
- **`web.goose`: extract the per-request body of `run_worker`** into
  ```goose
  // One parsed request through the framework; the static file index to send (or -1), and whether it was gweb dev's status request.
  fn respond<D>(req: const http::Request&, slot: i64, owner_fd: i32, cfg: Config, res: http::Response&) -> i64, bool
  ```
  It holds exactly today's branch: the `/__gweb/id` check, the trailing-slash redirect, `new_ctx`, `D(req, ctx, res)`, `apply_cookies`, and `dev_inject`. `run_worker` calls it from its `Ready` arm and keeps keep-alive, sending and logging. Behaviour does not change. This is why tests exercise the real path, not a copy that can drift.
- **New `testing.goose`** (`namespace web;`, `import web.testing;`):
  ```goose
  struct Tester { failures: i64 = 0, checks: i64 = 0, name: u8[..128] = "",
                  auto_csrf: bool = true, headers: u8[..2048] = "",   // extra header lines for the next request only
                  cookies: u8[..4096] = "" }                          // "name=value; name=value", the jar
  fn test_send<D, S>(t: Tester&, method: const u8[:], target: const u8[:], body: const u8[:], content_type: const u8[:]) -> http::Response
  fn expect(t: Tester&, ok: bool, what: const u8[:])
  fn expect_status(t: Tester&, res: const http::Response&, code: i64)
  fn expect_contains(t: Tester&, text: const u8[:], needle: const u8[:])
  fn expect_header(t: Tester&, res: const http::Response&, name: const u8[:], value: const u8[:])
  fn header_of(res: const http::Response&, name: const u8[:]) -> const u8[:], bool
  fn form_field(out: u8[>..]&, name: const u8[:], value: const u8[:])   // appends &name=value, URL-encoded
  ```
  `test_send` builds `METHOD target HTTP/1.1` with `Host: test`, a `Cookie` line from the jar, `Content-Type` and `Content-Length` when there is a body, and `t.headers` (then clears them). With `auto_csrf` and a non-GET method, it sends `X-CSRF-Token` with the jar's `gw_csrf` value; when the jar has none, it first puts the fixed token `00000000000000000000000000000000` into the jar. It parses with `http::parse_request`, calls `respond(req, 0, -1, cfg, res, D)` with `default_config()` and `workers = 1`, copies `S(i)` into `res.body` for a static file, and empties the body for HEAD. It then updates the jar from the `Set-Cookie` lines: `Max-Age=0` removes a cookie, others replace it by name. A failed check prints `FAIL <test>: <what>` and counts.

**gweb, in `cli/gweb.goose`:**
- `gen_main` splits into the shared body and a tail. The server tail is today's text. The test tail (`gen_test_main(tests)`) is used only by `gweb test`, written to `.gooseweb.test/routes_main.goose`, so the `embed_file("../…")` paths stay correct (Addendum 11).
- Each `tests/<name>.goose` (name `[a-z][a-z0-9_]*`) is copied through `copy_prefixed` as namespace `t_<name>`, mapped in `map.txt` so errors point at `tests/<name>.goose:LINE`. gweb collects each line that starts with `fn test_` and reads the name up to `(`.
- The test main defines `fn site::get`, `head`, `delete`, `post_form`, `post_json`, `put_json`, `patch_json` and `request(t, method, target, body, content_type)`, each calling `web::test_send(t, ..., dispatch, static_bytes)`, the same trick as `fn state::ask`.
- With `app/state.goose`, the test main defines `fn state::ask` as a direct call: it encodes the message with `to_bytes`, decodes it with `from_bytes`, calls `state::handle`, and round-trips the reply the same way. It runs on `main`, where the state lives, so it needs no channel. `state::init()` runs first when it exists.
- `main` prints `== <ns>::<test>` before each test (so an abort names the test), then `ok` or the failures. At the end it prints `routes: N tests, M checks, F failed` and exits 1 when F > 0.
- `gweb test` runs the component parity when `components/` exists (unchanged), then the route tests when `tests/` exists. If neither exists, it prints both "no ..." lines. It fails if either fails.

**Rules for authors:** tests run in file order and then in source order, and share state, the database and the cookie jar unless they reset `t.cookies`. Point the app's database at a test file through its environment variable (`SHOP_APP_DB` in the shop). An abort ends the run, after naming the test.

**Rejected:**
- Starting the server and using curl (as the `.sh` suites do): slower, needs a port, and cannot reach `state` or call helpers directly. The shell suites stay for what they cover.
- Copying `run_worker`'s branch into `testing.goose`: two copies drift. The extraction is small.
- Running each test in a contained thread so an abort is caught: globals are copied per thread, so `state` and the SQLite writer claim would not be the app's.
- A `test_` function in `route.goose` beside the route: it would compile into the production server.

## Decision 4: i18n

**Choice.** Message catalogs in `locales/`, compiled by gweb into a typed Goose module `t`. A missing key or a wrong argument is a build error, in the spirit of type-checked templates.

**Files:**
- `locales/default` holds one line: the default locale's tag. Required when `locales/` exists.
- `locales/<tag>.txt` for each locale; `<tag>` matches `[a-z]{2,3}(-[A-Za-z0-9]{2,8})*`.

```
# locales/en.txt
greeting = Hello, {name}!
cart_items[one] = {count} item in your cart
cart_items[other] = {count} items in your cart
stock = Only {n:int} left
```

**Syntax:**
- `key = text`, one per line. `#` starts a comment line; blank lines are skipped.
- A key is `[a-z][a-z0-9_]*`, not a Goose keyword, and not `tag`, `find` or `TAGS`.
- Text runs to the end of the line, trimmed. Escapes: `\n`, `\{`, `\}`, `\\`.
- `{name}` is a text argument (`const u8[:]`) and `{name:int}` an `i64`. Types are declared in the default locale only; other locales write `{name}` and may omit an argument, but may not add one.
- `key[cat]` gives plural forms, with `cat` one of `zero`, `one`, `two`, `few`, `many`, `other`. The default locale must give `[other]`. The selector is always the argument `count`, which is an `i64`.
- Arguments are ordered by first appearance in the default locale's file, `count` first for a plural key.

**Generated `.gooseweb/t.goose`** (namespace `t`, imported by every template and page through `add_default_imports`):

```goose
let TAGS = ["en", "de"];                                     // index 0 is the default
fn tag(ctx: const web::Ctx&) -> const u8[:]
fn find(tag: const u8[:]) -> i64, bool                       // case-insensitive exact match
fn greeting(ctx: const web::Ctx&, name: const u8[:]) -> u8[>..]
fn greeting(loc: i64, name: const u8[:]) -> u8[>..]           // for code with no Ctx
fn cart_items(ctx: const web::Ctx&, count: i64) -> u8[>..]
```

In a template: `<html lang="{t::tag(ctx)}">` and `<p>{t::cart_items(ctx, p.n)}</p>`. `{expr}` escapes the result, so messages are plain text; HTML inside messages is not supported in v1.

**Fallbacks:** a key missing from a locale uses the default locale's text. A missing plural form uses that locale's `[other]`. gweb prints `gweb: locales/de.txt lacks N keys (falls back to en): a, b` on a successful build; it becomes a warning once Addendum 18's warning channel exists. Build errors, each at `locales/<file>:LINE`: a syntax error, a duplicate key, a key the default locale does not have, an unknown or added argument, a type clash, a bad tag, a plural key without `[other]` in the default, and a missing `locales/default`.

**Runtime, new `i18n.goose` in goose-web** (`namespace web;`, imported by the generated `t.goose`):
- `fn plural_index(lang: const u8[:], n: i64) -> i64` gives 0–5 for zero to other, using CLDR integer rules for the language subtag. The table covers:
  - one when n is 1: en, de, nl, sv, da, nb, nn, it, es, pt-PT (as `pt` with a region other than BR), el, fi, et, hu, tr, bg, ca.
  - one when n is 0 or 1: fr, pt (including BR).
  - one/few/many: ru, uk, be, and pl. cs and sk use one/few/other.
  - other only: ja, zh, ko, vi, th, id, ms.
  - zero/one/two/few/many/other: ar.
  - one/two/other: he.
  - Any other language: one when n is 1, else other.
- `fn pick_locale(req: const http::Request&, tags: const u8[:][:]) -> i64`. The first rule that matches wins:
  1. The `locale` cookie, matched exactly.
  2. `Accept-Language`, by q-value. An exact tag wins, then the language part (`de-AT` takes `de`), then the first tag with that language (`en` takes `en-GB`).
  3. Index 0.
  It reads at most 16 entries. Matching ignores case.

**gweb hooks:**
- `web.goose` `Ctx` gains `locale: i64 = 0`, after `csrf`.
- When `locales/` exists, the generated `dispatch` sets `ctx.locale = web::pick_locale(req, t::TAGS);` after the static-file check, and adds `Vary: Accept-Language, Cookie` when there are two or more locales. Middleware may override `ctx.locale`.
- **URL-prefixed locales** (`/de/products`) need no new routing: use an `app/[lang]/` folder, with middleware that does `let i, ok = t::find(web::param(ctx, "lang")); if ok { ctx.locale = i; } else { web::not_found(ctx); return false; }`. The README documents this pattern.

**Not in v1:** translations inside `.gshtml` components (pass translated text in as data), number, date and currency formatting, and decimal plural operands.

**Rejected:**
- Gettext `.po` or ICU MessageFormat: their parsers are larger than the whole feature, and ICU's select and nesting are more than v1 needs.
- Run-time lookup by string key (`t(ctx, "greeting")`): a typo would be an empty string, not a build error.
- Locale in the URL as a built-in dispatcher rule: `[lang]` already does it, explicitly.

## Files and shared edit regions

- **goose-sqlite:** new `query.goose`, `test/test_query.goose`; `README.md` (a new `## Query builder` section after `## Writes`); `CHANGELOG.md`.
- **goose-web, new:** `testing.goose`, `i18n.goose`, `cli/i18n.goose`, `test/testing_test.goose`, `test/i18n_test.goose`, `test/routes.sh`, `test/routes/`, `test/i18n.sh`, `test/i18n/`.
- **goose-web, changed:**
  - `web.goose`: `run_worker`'s `Ready` arm, which moves into `respond`, and one `Ctx` field line after `csrf`. Other architects editing `run_worker` (Addenda 15 and 16) should rebase onto `respond`. Request-level work (logging, headers, compression) belongs in `respond` or around its call.
  - `cli/gweb.goose`: `gen_main` (split into a body and a tail), `test_cmd` (route tests appended), `gen` (`locales/` and `tests/` scanning), `gen_dispatch` (one locale line), `add_default_imports` (`import t;`), and `usage` (the test line).
  - `cli/gweb.build`: unchanged; `cli/i18n.goose` is imported by `gweb.goose`.
  - `README.md`: new sections `## Route tests` and `## i18n`, placed after `## Fragments`.
  - `CHANGELOG.md`: a `## v0.3.0 (unreleased)` entry.
  - `test/release_check.sh`: steps for the two new `_test.goose` files and the two new suites, after the catchall step.
- **Kept off:** `client/gwi.js`, `cli/component.goose`, `form.goose`, `csrf.goose`, `owner.goose`, and goose-net.

## Build plan

**Common to every builder:**
- Commit locally, never push, edit only inside the worktree you are given. One commit per step. End each message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Toolchain:** look for a compiler in `$GOOSE`, then `command -v goose`. If there is none, write the code and tests anyway, run whatever runs without it (`sh -n`, `node --check`, `python3`), and say in the commit message and the report that the step is untested.
- **Code style:** the one-line style of `sqlite.goose` and `web.goose`. Only why-comments and one-line API notes; no comments that cite this document.

**Step Q1 (goose-sqlite): the query builder.**
- Files: `query.goose`, `test/test_query.goose`, `README.md`, `CHANGELOG.md`.
- Build Decision 1 exactly, including the struct layout.
- `test/test_query.goose` is built with `$GOOSE build test/test_query.goose && test/test_query`, and prints "all query checks passed".
  - Text checks through `sql_text`: the select with where, raw, order, limit and offset gives `SELECT id, title, done FROM todos WHERE done = ? AND (title LIKE ?) ORDER BY id DESC LIMIT ? OFFSET ?`. Also check insert, update, delete with RETURNING, a join, and group_by.
  - `where_in` padding gives 1, 2, 4 and 8 placeholders for 1, 2, 3 and 5 values; an empty list gives `0 = 1`; 33 values is an error.
  - Each misuse in Decision 1 sets `query_error`, and `prepare` then fails.
  - A round trip on `test/q.db`: create, insert 3 rows, select with every where form, update with `all_rows`, delete by id, and check that two equal queries give the same `Stmt.h`.
- Done: the test passes (or is written and marked untested), the README section shows the example above, and the CHANGELOG gets `## v0.3.0 (unreleased)`.

**Step R1 (goose-web): `respond` and `testing.goose`.**
- Files: `web.goose` (the `run_worker` region only), `testing.goose`, `test/testing_test.goose`.
- `test/testing_test.goose` follows `cookie_test.goose`. It holds a hand-written `dispatch` and `static_bytes` pair:
  - a route that echoes the method and body;
  - a route that sets a cookie;
  - a route that answers 403 unless `web::csrf_ok`;
  - static index 0, with the bytes "STATIC".
- Checks:
  - status and body;
  - HEAD has an empty body;
  - a trailing slash gives 308 and a `Location`;
  - the jar keeps a cookie and then sends it;
  - `Max-Age=0` removes a cookie;
  - auto CSRF lets a POST through, and `auto_csrf = false` gives 403;
  - `t.headers` is sent once;
  - a static index gives "STATIC";
  - failing `expect_*` calls count failures.
- Done: the new test passes, `cookie_test`, `csrf_test` and `catchall_test` still pass, and `fragments.sh` still passes (it exercises `run_worker`). Or the step is marked untested.

**Step R2 (goose-web): `gweb test` runs `tests/`.**
- Files: `cli/gweb.goose` (the regions named above), `test/routes.sh`, `test/routes/site/` (app with a page, a route, `app/state.goose` with a counter `Msg`, a CSRF-protected page POST, a `public/` file, and `tests/basic.goose` with passing tests), `test/routes/failing/` (one failing check), `README.md` `## Route tests`, `CHANGELOG.md`, `test/release_check.sh`.
- `test/routes.sh` checks:
  1. `gweb -C site test` passes and prints `routes: N tests`.
  2. The state counter increments across two tests (the state is shared).
  3. `failing` exits 1 and prints `FAIL t_bad::test_x`.
  4. A type error in a test file is reported at `tests/<name>.goose:LINE`.
  5. `.gooseweb/` is untouched (as in Addendum 11).
- Done: `routes.sh`, `components.sh` and `templates.sh` pass, or the step is marked untested.

**Step I1 (goose-web): i18n runtime.**
- Files: `i18n.goose`, the `Ctx` line in `web.goose`, `test/i18n_test.goose`.
- Checks:
  - `plural_index` for en 0/1/2, fr 0/1/2, ru 1/2/5/11/21/22/25, pl 1/2/5/22, cs 1/2/5, ja 1, ar 0/1/2/3/11/100, he 1/2/3, and an unknown language;
  - `pick_locale` for the cookie, an exact tag, q ordering, `de-AT` taking `de`, `en` taking `en-GB`, case, garbage, no header, and more than 16 entries.
- Done: the test passes, or the step is marked untested. Do not touch `cli/` or the README.

**Step I2 (goose-web): the catalog compiler.**
- Files: `cli/i18n.goose` (parser and code generator, `namespace i18n;`), `cli/gweb.goose` hooks, `test/i18n.sh`, `test/i18n/site/` (en and de, a plural key, a page using `t::`), `test/i18n/fail/` (one folder per build error), `README.md` `## i18n`, `CHANGELOG.md`, `test/release_check.sh`.
- `test/i18n.sh` builds and starts the site, then curls:
  - `Accept-Language: de` gives German, and `Vary` is set;
  - the `locale=en` cookie overrides it;
  - plural forms for 1 and 2;
  - a missing de key falls back to English;
  - the build prints the "lacks" line;
  - escaping: a message with `<` is escaped;
  - each fail folder fails with its `locales/<file>:LINE` message.
- Done: `i18n.sh`, `templates.sh` and `catchall.sh` pass, or the step is marked untested.

**Order:** Q1 and R1 run in parallel (different repos). Then R2 and I1 run in parallel, on disjoint files, each committing only its own paths. I2 runs last. The Postgres driver is not built.

## Open questions for the user

1. **Where should the Postgres driver live?** A new `goose-pg` repo (default in this design), or inside goose-sqlite as a renamed `goose-sql` package? Related: once two drivers exist, should the query builder's core move to its own small package (default: yes, `goose-sql`, with both drivers depending on it)?
2. **`locales/default` file versus a convention** (the default locale is `en` when present). Default: the explicit file.
3. **Should route tests isolate state between tests** (rerun `state::init` per test, which is impossible for a SQLite writer claim), or share it (default)?
4. **Version.** These additions go under `v0.3.0 (unreleased)`; no `VERSION` bump until release.

## Build log

No Goose compiler exists on this machine (`$GOOSE` unset, none on `PATH`, the Addendum 10 SDK path missing). Every step was written and reviewed but **none was compiled or run**. Only `sh -n` ran on the shell suites. The first job with a compiler is to run every test named below and fix what fails.

| Step | Repo, branch | Commits | Status |
|---|---|---|---|
| Q1 query builder | goose-sqlite `arch/platform` | `97d9307` | written, untested |
| R1 `respond` and `web.testing` | goose-web `arch/platform` | `4eb72d8`, `a826a59` | written, untested |
| R2 `gweb test` runs `tests/` | goose-web | `e896b11`, `7cce428`, and the `gw_t` rename | written, untested |
| I1 i18n runtime | goose-web | `1785aac` | written, untested |
| I2 catalog compiler | goose-web | `13dab61` | written, untested |
| Postgres driver | none | none | designed only (Decision 2) |

**Review fixes by the architect:**
- `test_send` compared a payload enum with `!=`; it now uses `match`.
- `header_of` now answers `Content-Type` from `res.content_type`, which is not in `res.headers`.
- `gweb test` writes `.gooseweb.test/site.goose` (`namespace site;`), so `fn site::get` has a namespace to define into. That namespace mirrors `state`, which exists as a file.
- The generated test main's Tester is named `gw_t`, so it cannot shadow the `t` i18n namespace.

**Builder choices accepted beyond the design:**
- Q1:
  - `table` must be a plain identifier, so aliases go in joins and columns only.
  - `LIMIT ? OFFSET ?` always come as a pair; an offset alone binds a limit of -1.
  - Extra misuse errors: an `arg` with no pending `?`, select-only clauses on other kinds, `returning` on a SELECT, a negative limit, and empty raw text.
  - The whole-query checks run in `query_error`, `sql_text` and `prepare`.
- R2: the final count is failed checks, not failed tests. Test output is printed when the run ends, not streamed.
- I2:
  - Extra build errors: a key that is both plain and plural, duplicate tags, unknown escapes and types, and `gw_`-prefixed and reserved names.
  - `:int` must be written at an argument's first use in the default locale.
  - `gweb dev` also watches `locales/`.
  - Routes and middleware must `import t;` themselves.

**Unverified Goose points to check first:**
- Passing a generic function parameter on (`respond(..., D)`) and assigning a tuple result into existing `var`s.
- Overloads that differ only in the first parameter type (`Ctx` against `i64`).
- Writes to outer `var`s from inside `each_split` blocks (`pick_locale`).
- Local fixed arrays of slices (`const u8[:][16]`).
- `u8` to `i64` casts.
- A sub-module of package `sqlite` that does `import sqlite;`.
