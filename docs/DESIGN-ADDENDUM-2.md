<!-- Produced by goose-architect on claude-fable-5-2 -->
# goose-web decisions: worker count, 256-client errors, SQLite

I ran measurements against the built shop server and prototyped the SQLite package in the scratchpad; nothing under `~/Documents` was changed. The headline: the multi-worker slowdown is not a goose-web loop problem, the 256-client errors look like accept starvation plus the 128 backlog, and SQLite should be a per-worker read-only connection in a separate `goose-sqlite` package.

## Question 1: worker count

### What I measured (`/products/42`, keep-alive, this Mac)

| Setup | Total req/s | Server CPU per request |
|---|---:|---:|
| 1 server ×1 worker, 16 clients | 223,588 | 4.5 µs |
| 2 independent servers ×1, 16 clients each (2 loadgens) | 210,563 | 7.9 µs |
| 4 independent servers ×1, 16 clients each (4 loadgens) | 191,973 | 11.7 µs |
| 1 server ×2 workers, 32 clients | 211,927 | 9.0 µs |
| 1 server ×4 workers, 64 clients | 170,322 | 20.6 µs |
| 1 server ×6 workers, 64 clients | 155,494 | 33.6 µs |
| 4 independent servers ×1, 64 clients each | 186,383 | 16.8 µs |

- **Separate processes hit the same wall.** Four unrelated server processes on four ports, each with its own loadgen, total less than one server alone. So the shared listen fd, `poll` per wake and `accept_max=1` are not the cause; the limit is machine-wide (kernel loopback path and/or the client threads).
- **The client is expensive.** loadgen used 7.9 CPU-seconds in a 2.2 s run against one worker (about 3.6 cores, 7.2 s of it system time), and 13.3 CPU-seconds against four workers.
- **Pinning loadgen does not help.** `taskpolicy -b` (efficiency cores only) dropped ×1 to 149,530 req/s; `taskpolicy -c utility` changed nothing (235,582 at ×1, 167,711 at ×4).

So on this machine tiny responses top out near 230k req/s whatever the server does, and extra workers only add contention. Your own table shows workers do help once the handler does real work: `/products` 99k → 148k and `/api/todos` 73k → 116k from ×1 to ×4.

### Decisions

- **Default worker count: `min(performance cores, 4)`.** Read the performance-core count with `sysctlbyname("hw.perflevel0.logicalcpu")` on macOS (6 here), falling back to `hardware_threads()` elsewhere. `--workers` and `WEB_WORKERS` still override.
  - Why 4: the heavy routes were best at ×4 (148k–152k) and worse at ×18 (120k–134k); light routes fall with every added worker.
  - I only have heavy-route data at 1, 4 and 18. Run a sweep of 1, 2, 4, 6 on `/products` and the DB list route; if 6 beats 4 by more than 5%, raise the cap to the performance-core count.
- **Loop: no change for throughput.** Keep `poll` and the shared listen fd.
- **Benchmarking multi-core on one machine:**
  1. Treat goose ×1 on `/api/health` at the same client level as the loopback ceiling for that run.
  2. In tiers 2 and 3, mark any cell whose ×1 rate is above half the ceiling as "loopback-limited" in `summarize_shop.py`; judge scaling only on the rest (`/products`, `/api/products`, `/api/todos`, the DB list routes).
  3. Add a worker-sweep table (1, 2, 4, 6) for `/products` and `/db/products`, with speedup over ×1.
  4. Keep reporting server CPU per 10k requests; it is the number that is not client-limited.

### Rejected

- All cores (current): the worst result on every route, and it puts workers on efficiency cores.
- 1 worker: throws away the 1.5× on heavy routes.
- kqueue/epoll rewrite now: the separate-process experiment says it would not move this number. Worth revisiting for thousands of idle connections.
- Packing connections onto few workers: complexity aimed at a loopback artefact.

### Risks

- The cap of 4 is tuned on same-machine loopback on macOS; a Linux server with a real NIC may want more.
- I did not identify which kernel path is the limit, only that it is outside the server process.

## Question 2: errors at 256 clients

### What I found

- **Accept is starved under load.** `gnet_loop_next` only calls `poll` when no connection has a buffered request, and each poll pass accepts one connection (`accept_max=1`). With one worker, every pass first serves every already-connected client, so connecting N clients takes time proportional to N².
- **The ramp shows up in max latency.** One worker on `/api/todos`: 76 ms at 120 clients, 109 ms at 160, 172 ms at 200, 288 ms at 256.
- **Errors are mostly reads, and intermittent.** One run gave "connect 11, send 32, read 3996"; a repeat at 256 gave 0 errors but only 50k req/s. `/api/products` gave "connect 33, send 35, read 1211".
- **loadgen amplifies it.** A client whose request fails reconnects at once and counts another error, so a few dropped connections become thousands.

My reading, not proven: 256 simultaneous connects overflow the 128 listen queue while the worker is slow to accept, the kernel drops queued connections, and those clients see read failures. It fits slow routes being worst, ×4 and all-cores being nearly clean, and Next erroring on everything.

### Decisions

1. **`/Users/joeheinz/Documents/goose-net/src/loop.c`:** count requests handed out since the last poll. At 16, run one poll pass with timeout 0 (fill and accept) before handing out more.
2. **`/Users/joeheinz/Documents/goose-web/web.goose` `run_worker`:** pass `accept_max = 0` when `cfg.workers == 1`, keep 1 otherwise.
3. **Backlog:** leave it. The kernel caps it at 128; do not have the harness change `kern.ipc.somaxconn`. Mention `sudo sysctl -w kern.ipc.somaxconn=1024` in the README as optional.
4. **Owner channel:** no change. It only matters here because it makes each pass slower.
5. **`/Users/joeheinz/Documents/goose-bench/loadgen/loadgen.goose`:**
   - Connect before timing: clients connect in waves of 32, 10 ms apart, with up to 5 retries 50 ms apart; all start sending at a common `start_ns` carried in `Job`.
   - After a mid-run failure, wait 10 ms before reconnecting.
   - Add connect, send and read error counts as CSV columns.
   - Collect latencies per thread and send one batch at the end, instead of one `qput` per request.
6. **Keep the 256 level.** A cell with errors above 0.1% of requests is printed as "invalid (n errors)", not as a rate.

Done means: goose ×1 at 256 clients shows 0 errors on all URLs across 3 runs, and max latency under 50 ms. If Next still errors after the loadgen ramp, that is a real result and stays in the table.

### Risk

If errors persist after items 1, 2 and 5, the hypothesis is wrong; the next step is to log `errno` per failed read in loadgen.

## Question 3: SQLite

### a) Where the connection lives

- **One read-only connection per worker thread**, opened lazily on first use and kept in C thread-local storage. Statements are cached per connection.
- **A separate package, `goose-sqlite`** (module `sqlite`) at `/Users/joeheinz/Documents/goose-sqlite`, sibling of goose-web. goose-web itself does not link SQLite.
- **One gweb change:** when any file under `app/` or `lib/` contains `import sqlite;`, the generated root adds `import sqlite from "<goose-web>/../goose-sqlite";`.
- **No `app/db.goose` convention.** The shop wraps its queries in `lib/shopdb.goose`.
- Writes are out of scope for the shop. The pattern for later: `state.goose` opens a read-write connection in `init`, so the owner is the single writer.

Prototype, built and run from `thread_fn` workers: `/private/tmp/claude-501/-Users-joeheinz--claude-spares-spare-sGecwS/10d9fa68-9193-489c-9d6d-af48a0a097a1/scratchpad/q3/goose-sqlite/` (`sqlite.goose`, `sqlite.build`, `src/sqlite.c`, `test/t.goose`). Copy it as the starting point.

| Threads | Point lookup by id | 100-row list |
|---:|---:|---:|
| 1 | 1.4 µs | 6.2 µs |
| 4 | 2.8 µs | 7.4–7.9 µs |
| 12 | about 14 µs | about 15 µs |

Rejected:
- Owner thread holds the DB: every query costs a socketpair round trip and all reads serialize.
- One shared connection: needs SQLite's serialized mode and a lock on every call.
- Building it into `web`: forces libsqlite3 on every app.

### b) API (`/Users/joeheinz/Documents/goose-sqlite/sqlite.goose`)

```goose
namespace sqlite;
struct Db { h: u64 }
struct Stmt { h: u64 }
enum Mode { ReadOnly, ReadWrite, Create }

fn local(path: const u8[:], mode: Mode = Mode.ReadOnly) -> Db   // this thread's connection, opened once
fn open(path: const u8[:], mode: Mode = Mode.ReadOnly) -> Db    // a fresh one; the caller closes it
fn close(db: Db)
fn ok(db: Db) -> bool
fn ok(s: Stmt) -> bool
fn error(db: Db) -> u8[>..]                                     // also explains a failed open
fn exec(db: Db, sql: const u8[:]) -> bool
fn prepare(db: Db, sql: const u8[:]) -> Stmt                    // cached per connection by SQL text; comes back reset
fn bind(s: Stmt, i: i64, v: i64) -> bool                        // i is 1-based
fn bind(s: Stmt, i: i64, v: f64) -> bool
fn bind(s: Stmt, i: i64, v: const u8[:]) -> bool
fn bind_null(s: Stmt, i: i64) -> bool
fn step(s: Stmt) -> bool                                        // true while there is a row; resets itself at the end
fn reset(s: Stmt)                                               // needed only when stopping early
fn int(s: Stmt, col: i64) -> i64                                // col is 0-based
fn float(s: Stmt, col: i64) -> f64
fn is_null(s: Stmt, col: i64) -> bool
fn text(s: Stmt, col: i64, out: u8[>..]&)                       // appends a copy
fn text(s: Stmt, col: i64) -> u8[>..]                           // a fresh copy
fn text_len(s: Stmt, col: i64) -> i64
fn changes(db: Db) -> i64
fn last_insert_id(db: Db) -> i64
```

- **Text is always copied.** An `extern fn` cannot return a slice ("nested references and slices do not cross", verified), so there are no views and nothing for the lifetime checker to object to.
- **Errors:** `ok()` on the handle, `bool` from calls, message from `error(db)`. A failed step returns false like end-of-rows; check `error` when it matters.
- The prototype lacks `close`, `bind_null`, `is_null`, `changes` and `last_insert_id` on the Goose side (the C has all but `close`).
- `sqlite.build`: `c_sources = ["src/sqlite.c"]; c_libs = ["sqlite3"]; exclude = ["test"];`

### c) Schema, seed, location

```sql
CREATE TABLE products (
  id INTEGER PRIMARY KEY, name TEXT NOT NULL, category TEXT NOT NULL,
  cents INTEGER NOT NULL, featured INTEGER NOT NULL, description TEXT NOT NULL);
CREATE INDEX products_featured ON products(featured, id);
```

- Products only.
- `/Users/joeheinz/Documents/goose-bench/shop/gen_data.py` writes the same rows it already builds to two files with Python's `sqlite3`: `/Users/joeheinz/Documents/goose-web/examples/shop/data/shop.db` and `/Users/joeheinz/Documents/goose-bench/next-shop/data/shop.db` (and `next-shop-static/data/shop.db`).
- Journal mode WAL, then `PRAGMA wal_checkpoint(TRUNCATE)` before closing.
- Each server opens `$SHOP_DB` if set, else `data/shop.db` relative to its working directory (the harness already starts each server in its site folder).

### d) Routes and the Next side

Keep the in-memory routes; add DB twins under `/db`:

| URL | goose-web files (under `examples/shop/app/`) | Query |
|---|---|---|
| `/db` | `db/page.goose`, `db/page.html` | featured |
| `/db/products` | `db/products/page.goose`, `page.html` | all |
| `/db/products/[id]` | `db/products/[id]/page.goose`, `page.html` | one |
| `/api/db/products` | `api/db/products/route.goose` | all |
| `/api/db/products/[id]` | `api/db/products/[id]/route.goose` | one |

The three statements, identical text on both sides:
- `SELECT id, name, category, cents, featured, description FROM products WHERE id = ?`
- `... FROM products WHERE featured = 1 ORDER BY id`
- `... FROM products ORDER BY id`

`/Users/joeheinz/Documents/goose-web/examples/shop/lib/shopdb.goose`:

```goose
namespace shopdb;
struct Product { id: i64, name: u8[..64], category: u8[..16], cents: i64, featured: bool, description: u8[..256] }
fn conn() -> sqlite::Db                       // sqlite::local(path); path cached in a flat global
fn product(id: i64, p: Product&) -> bool      // false: no such row or DB error
fn featured(out: Product[>..]&) -> bool
fn all(out: Product[>..]&) -> bool
```

Page `Props` hold `shopdb::Product` or `items: shopdb::Product[>..]` as the last field. A DB failure answers 500.

Next (`make_next_shop.py` generates these):
- `lib/db.js`: one `new DatabaseSync(path, { readOnly: true })` and the three `db.prepare(...)` at module scope; export `one(id)`, `featured()`, `all()` using `.get` / `.all`.
- `app/db/page.js`, `app/db/products/page.js`, `app/db/products/[id]/page.js`, `app/api/db/products/route.js`, `app/api/db/products/[id]/route.js`, each with `export const dynamic = "force-dynamic"`.
- Under the cluster wrapper each process gets its own connection.

I checked `node:sqlite` opens the same WAL file read-only on Node 24.19 without a flag. In a bare Node loop the 100-row `.all()` took about 37 µs.

`check_site.py`: each `/db` URL must return the same key substrings as its in-memory twin, on both sites.

### e) Benchmark rows (`bench_shop.py`)

```python
DB = ["/api/db/products/42", "/api/db/products", "/db", "/db/products", "/db/products/42"]
```

- Add `DB` to: t1 goose ×1, t1 next-dynamic ×1, t2 goose ×4, t2 next-dynamic ×4, t3 goose default.
- Not next-static: its pages would still be dynamic, so it duplicates next-dynamic.
- `summarize_shop.py`: a "DB-backed routes" section with the usual per-URL tables, plus a "DB overhead" table pairing each `/db` URL with its in-memory twin at 64 clients for goose ×1 and next-dyn ×1.

### Risks

- **Reader contention:** lookups slow from 1.4 µs to about 14 µs at 12 threads. With the default of 4 workers it is 2.8 µs.
- **Reusing a statement while iterating it:** `prepare` with the same SQL returns the same statement, reset. Nested use of one query breaks the outer loop.
- **Leaks:** thread-local connections are never closed, and a respawned worker opens a new one.
- **Fixed-size fields:** a name over 64 or description over 256 bytes must be truncated by `shopdb` before appending, or the append aborts. Current data fits.
- **Linux:** needs the libsqlite3 development package.
- **Next build:** I did not test `node:sqlite` inside a Next build, only in plain Node.
- **Different SQLite versions:** system 3.54 vs Node's bundled 3.53.3.

## Follow-up 1: WAL and read-only connections

# Correction to question 3c: seed in rollback-journal mode

**Decision: option 1.** `gen_data.py` creates `shop.db` with `PRAGMA journal_mode=DELETE` and no checkpoint step. You are right that my prototype only worked because the `-wal` and `-shm` files were still beside the database.

I re-ran the prototype against a DELETE-mode database with no side files:

| Reader | Point lookup by id | 100-row list |
|---|---:|---:|
| goose-sqlite, 1 thread | 3.2 µs | 8.2 µs |
| goose-sqlite, 4 threads | 5.8 µs | about 10 µs |
| goose-sqlite, 12 threads | about 23 µs | about 25–27 µs |
| `node:sqlite`, `readOnly: true` | 3.1 µs | not measured |

- **Read-only opens succeed and queries run**, from `thread_fn` workers and from Node, and no extra files appear beside `shop.db`.
- **Lookups cost about twice the WAL figure** (3.2 µs vs 1.4 µs single-threaded). Both sites pay the same, so the comparison stays fair.

**Next's `lib/db.js`:** unchanged from the plan — `new DatabaseSync(path, { readOnly: true })` and the three prepared statements at module scope. No pragmas on either side.

**goose-sqlite API:** no change to `local()` or `open()`. Add one line to its README: a `ReadOnly` open of a WAL database fails at the first `prepare` unless the `-shm` file already exists, so read-only deployments should use rollback-journal mode.

**Rejected:**
- Option 2 (open read-write behind a `ReadOnly` request): the mode would lie, and it needs a writable directory.
- Option 3 (`immutable=1`): skips all locking, which flatters the numbers and is unsafe if anything ever writes; `node:sqlite` would need the same URI handling to match.

**Risk:** the 12-thread figure is worse than under WAL, though the default of 4 workers keeps it at 5.8 µs.
