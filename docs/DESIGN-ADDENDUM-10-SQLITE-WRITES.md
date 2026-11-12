<!-- Produced by goose-architect on claude-opus-5-5 (medium) -->
# goose-web decisions: the SQLite write path (v0.2.0)

Scope: how a goose-web app writes to SQLite, which parts belong in goose-sqlite and which in goose-web, and a persistent shop demo. The benchmark read path stays as it is.

## What the decisions rest on

**Measured by the earlier prototype** (scratchpad `arch-sqlwrite/`, system libsqlite3 3.54, this Mac; programs `exp/e1.goose` to `e3.goose`):

| Exp | Setup | Result |
|---|---|---|
| E1 | 4 threads, each reading `shop.db` (rollback journal, `ReadOnly`) and inserting into `app.db` (WAL, read-write), 500 iterations each | 0 failures of any kind; 2,000 rows; `shop.db` still `delete` mode, no `-wal`, `-shm` or `-journal` beside it |
| E2a | 4 threads × 500 `BEGIN IMMEDIATE`, insert, update counter, commit (busy timeout 2 s) | 0 begin or commit failures; counter 2,000 |
| E2b | 1 writer, 2,000 autocommit inserts, WAL, `synchronous=NORMAL` | 9 µs mean, 1.4 ms max |
| E2c | the same with `synchronous=FULL` | 72 µs mean, 3.5 ms max |
| E2d | E2b while 3 threads run point SELECTs | writer 22 µs mean, 2.2 ms max; readers 3.4 µs per SELECT, 0 failures |
| E3 | 4 threads open read-write with `PRAGMA query_only=1` on a WAL file | 0 failures in 4,000 SELECTs; an INSERT on such a connection fails with "attempt to write a readonly database", code 8; while another thread inserted 100 rows, all 4 readers saw all 101 counts |

**Not measured.** The earlier prototype planned E4 (abort inside a transaction), E5 (migration race) and E6 (result codes) but did not run them. Its `ReadOnly` contrast run in E3 is not valid. The `-wal` and `-shm` files were still on disk, because Apple's `/usr/bin/sqlite3` leaves them behind on close. In that same session, the Homebrew `sqlite3 -readonly` failed with "unable to open database file (14)" once those files were removed. This agrees with DESIGN-ADDENDUM-2 Follow-up 1 and with CMS-STUDY.

**From the code and docs:**
- goose-sqlite already has `exec`, `changes`, `last_insert_id` and the `ReadWrite` and `Create` modes. It has no transactions, no row-id return from a statement, no error codes and no reader mode that works with WAL.
- `state::init()` runs on `main` before the workers spawn. `state::handle` runs only on `main` (`main.goose`, which gweb generates).
- Goose reference §22 (around line 2831): "Nothing runs a defer" on `abort`, including a contained worker's abort. Resources opened through `extern fn` stay open. So a worker that aborts in the middle of a transaction keeps its connection and its lock.
- `/api/todos` is a benchmark row (`bench_shop.py` STATE), measured against Next's in-memory todos. `/db*` and `/api/db*` read `shop.db`, and so does `next-shop`'s `node:sqlite` `readOnly` connection.

## Decision 1: writes run on the owner thread

**Choice.** Each database has one read-write connection. It lives on `main`, the state owner. `state::init` opens it, and `state::handle` uses it. Workers never write. They send a typed `Msg`, and the owner binds, steps and commits.

**Why:**
- **One writer per process means no lock contention between writers.** SQLite serializes writers anyway. With several writer connections, a write that has to wait sits in the busy handler's sleep loop, which sleeps in steps of milliseconds. The owner's queue serves writes in order instead, without sleeping.
- **An abort cannot leave the lock held.** Per §22, a worker that aborts in a transaction keeps the write lock until the process exits, and every later write fails. An abort on `main` ends the process, and SQLite then discards the uncommitted WAL frames.
- **The cost is small.** One owner round trip is about 9 µs (CMS-STUDY) and an insert 9–22 µs (E2b, E2d), so a write costs about 20–30 µs.
- **No framework change is needed.** `state.goose` may already `import sqlite;`, because gweb's `copy_prefixed` checks it. `init` already runs before the workers start.

**Rejected:**
- Writing on the worker (W2): an abort in a transaction leaks the lock (§22), and writers contend through busy-wait sleeps.
- A dedicated writer `thread_fn`: Goose has no shared memory, so it would need a second channel set, which duplicates the owner.
- A separate admin process (W3): a deployment concern, not a framework default.
- A generic "write batch" `Msg` built into gweb (CMS-STUDY): gweb would have to compose state modules, in `cli/gweb.goose`, which Addendum 8 is editing. Defer it until a CMS needs it.

**Risks:**
- **Every write blocks all owner traffic for its duration**, including the in-memory `/api/todos`. That is typically 10–20 µs, and 1.4–2.2 ms when an auto-checkpoint runs (E2b, E2d).
- **An abort in `state::handle` ends the server.** This risk already exists. Rule: workers validate and size every value; the owner only binds, steps and commits.

## Decision 2: WAL for written databases; benchmark data stays in rollback-journal mode

**Choice:**
- **Written databases use WAL with `synchronous=NORMAL`.** The writer turns WAL on when it opens the file.
- **`shop.db` stays read-only, in `journal_mode=DELETE`, unchanged.** The demo's writes go to a separate file, `data/app.db`, or `$SHOP_APP_DB`.
- **Workers read a written database through a new mode, `Mode.QueryOnly`.** It opens read-write without create, then runs `PRAGMA query_only=1`.

**Why:**
- **Readers of a written database must not depend on the order connections open.** A `ReadOnly` WAL open fails at `prepare` unless the `-shm` file exists (DESIGN-ADDENDUM-2 Follow-up 1, CMS-STUDY). A `QueryOnly` connection may create the `-shm`, so it works in any order (CMS-STUDY C test). It still rejects writes with code 8 (E3).
- **Rollback journal plus a writer fails.** CMS-STUDY measured 199 of 200 writes failing with `SQLITE_IOERR_LOCK` while read-only readers were open. WAL readers never block the writer, and the writer never blocks them (E2d).
- **A separate file keeps `shop.db` and its Next twin exactly as they are.** E1 shows that both modes coexist in one process and that `shop.db` gains no side files.

**Rejected:**
- Converting `shop.db` to WAL: this changes the benchmark comparison with `next-shop`'s `readOnly` connection, and gains nothing for a database nobody writes.
- `ReadOnly` readers that rely on the owner opening first: this works only while the owner's connection keeps the `-shm` alive. That holds today, but it is a hidden ordering rule.
- `immutable=1` readers: they would not see any write.

**Risks:**
- **A `QueryOnly` reader needs write permission on the directory** (for the `-shm`). The writer needs that permission anyway.
- **Apple's libsqlite3 leaves `app.db-wal` and `app.db-shm` on disk after close**, as seen with `/usr/bin/sqlite3`. Git must ignore them.

## Decision 3: the API, and where each part lives

**goose-sqlite (v0.2.0)** gets everything that touches SQLite. These are additions only; no existing signature changes:

```goose
enum Mode { ReadOnly, ReadWrite, Create, QueryOnly }        // QueryOnly: read-write open, then query_only=1

fn writer(path: const u8[:], durable: bool = false) -> Db   // this thread's writer for path; see below
fn run(s: Stmt) -> bool                                     // steps to the end, resets; true on SQLITE_DONE
fn insert(s: Stmt) -> i64, bool                             // run; the new row id
fn update(s: Stmt) -> i64, bool                             // run; rows changed (UPDATE, DELETE)
fn begin(db: Db) -> bool                                    // BEGIN IMMEDIATE
fn commit(db: Db) -> bool
fn rollback(db: Db)                                         // only when a transaction is open
fn code(db: Db) -> i64                                      // extended result code of the last failure
fn busy(db: Db) -> bool                                     // (code & 255) == 5
fn constraint(db: Db) -> bool                               // (code & 255) == 19
fn set_busy_timeout(db: Db, ms: i64)
fn version(db: Db) -> i64                                   // PRAGMA user_version
fn migrate(db: Db, steps: const u8[:][:]) -> bool           // see Decision 5
```

`writer(path, durable)`:
- **It opens the file read-write and creates it if missing.** The connection lives in the calling thread's `local` cache, under a mode code of its own.
- **It requires `PRAGMA journal_mode=WAL` to answer `wal`.** It then sets `synchronous=NORMAL`. With `durable`, it sets `synchronous=FULL` and `fullfsync=1`.
- **It sets a busy timeout of 1,000 ms.**
- **It claims `path` for the calling thread for the life of the process.** The claim list is process-wide, in C, behind a mutex. A call from any other thread returns a failed `Db`, and `error` reports "another thread is the writer for <path>". A second call on the owning thread returns the cached handle. This makes the single-writer rule something the code checks, not a convention.
- **Prepared write statements are the existing `prepare` cache.** The writer connection caches `INSERT`, `UPDATE` and `DELETE` statements by SQL text, as reads are cached today. Values are always bound; SQL is never built from input.
- **Transaction idiom:**
  ```goose
  if !sqlite::begin(db) { return fail(db); }
  defer sqlite::rollback(db);
  ...
  return sqlite::commit(db);
  ```
  `rollback` does nothing once the commit has succeeded.

**goose-web** changes no runtime code: `web.goose`, `owner.goose`, `src/owner.c` and `cli/gweb.goose` stay as they are. The pattern lives in the app's `app/state.goose` and a `lib/` file. goose-web's README documents it.

**The app maps errors to statuses:**
- `busy` gives 503.
- `constraint` gives 409.
- Any other database failure gives 500.
- An affected-row count of 0 gives 404.

The app does this mapping itself, because a `web::` helper would tie goose-web to SQLite codes.

**Rejected:**
- `wal(db, durable)` as a public call next to `writer`: two ways to set up a writer. `writer` covers it.
- Returning statuses from goose-sqlite: HTTP belongs to the app.
- A `Db` stored in a `state` global: workers get a copy of flat globals when they spawn (§22). A copied handle used from a worker is a cross-thread use of a `NOMUTEX` connection. `writer(path)` on each call costs only a list walk, and the claim catches misuse.

**Risks:**
- **The claim is keyed by the path text.** `data/app.db` and `./data/app.db` are two claims. Document it.
- **`code` after a failed `run` relies on `sqlite3_reset` keeping the error.** Step 1.1 tests this.

## Decision 4: busy handling and durability

- **The owner never contends with itself.** Busy comes only from another process, such as the `sqlite3` CLI, a backup, or an overlapping `gweb dev` restart.
- **The writer waits at most 1,000 ms.** A stalled write blocks every `state::ask`. One second bounds that and stays under the worker's 5 s reply timeout. Because every write message is one `BEGIN IMMEDIATE` transaction, only `begin` can wait.
- **Readers keep the existing 2,000 ms.** WAL readers wait only during recovery.
- **The default is `synchronous=NORMAL`** (E2b: 9 µs, against 72 µs for FULL in E2c). In WAL mode it loses no commit when the process crashes and never corrupts the file. Only an OS crash or power loss can drop the last commits.
- **`durable: true` gives FULL plus `fullfsync`.** On macOS, FULL without `fullfsync` is not power-safe. Its cost with `fullfsync` is not measured; step 1.4 measures it, for information only.

**Rejected:** FULL as the default, at 8 times the commit cost for a guarantee most demos and CMS sites do not need. The user may choose otherwise (User decision 1).

## Decision 5: schema setup at startup

**Choice.** `sqlite::migrate(db, steps)` runs in `state::init`, on `main`, before the workers start.
- **Step `i` takes `PRAGMA user_version` from `i` to `i + 1`.** A step may hold several statements (it uses `exec`).
- **`migrate` reads the version without a lock**, and returns at once if the version matches.
- **Otherwise it runs `BEGIN IMMEDIATE` and reads the version again under the lock.** It applies the missing steps, sets `user_version`, and commits. A failure rolls everything back.
- **A version newer than `steps.len` returns false.** `init` prints the error and calls `exit(1)`.
- **`writer` runs before `migrate`**, because `journal_mode` cannot change inside a transaction.
- **Any start-up failure ends the server.** This covers a failed open, WAL or migration.

**Rejected:**
- Migration files on disk: they add a loader for no gain at this size.
- Down-migrations: out of scope.
- Migrating lazily on the first request: this races between workers, which was the purpose of E5.

**Risk.** A migration that runs long delays the server's first request. That is acceptable at start-up.

## Decision 6: the benchmark read path

**Unchanged:** `shop.db`, `lib/shopdb.goose`, `gen_data.py`, `bench_shop.py`, `make_next_shop.py`, every template, `app/layout.html`, and the `/db` pages. `/products/42` stays byte-identical, because no layout or nav changes; the new page gets no nav link.

**Two changes reach the measured routes:**
- **`state::Reply` gains `db_code: i64 = 0`**, placed before `todos`. Each `/api/todos` reply frame grows by 8 bytes.
- **The thread-exit cleanup (step 1.6), if adopted, adds one pointer step to `gsq_local`.**

The gate is that `/api/todos`, `/db/products`, `/db/products/42`, `/api/db/products/42` and `/products/42` each stay within 3% of the Phase 0 baseline in requests per second at 64 clients with 1 worker. Re-run the baseline first to learn the noise.

## Decision 7: the shop demo

**Choice.** Persistent todos are a **database twin**, as the products got in Addendum 2. The in-memory todos and `/api/todos` stay unchanged, because they are the STATE benchmark row against Next.

| URL | Files under `examples/shop/` | Reads | Writes |
|---|---|---|---|
| `/api/db/todos` | `app/api/db/todos/route.goose` | GET: worker, `QueryOnly` | POST: `state::ask(DbAdd)`, returns 201 |
| `/api/db/todos/[id]` | `app/api/db/todos/[id]/route.goose` | GET: worker | PUT: `DbUpdate`; DELETE: `DbRemove` |
| `/db/todos` | `app/db/todos/page.goose`, `page.html` | load: worker | POST form (`add`, `done`, `undo`, `remove`), one `todo-list` fragment, built like `/fragments` |

**`lib/todosdb.goose`** (namespace `todosdb`) holds all the demo's SQL:
- **The path** is `$SHOP_APP_DB`, else `data/app.db`. It is cached in a flat global, like `shopdb`.
- **`struct Todo { id: i64, title: u8[..200], done: bool }`.**
- **Owner only:**
  - `fn open() -> bool`: `writer`, then `migrate`.
  - `fn add(title) -> Todo, i64`
  - `fn update(id, title, has_title, done, has_done) -> Todo, i64`
  - `fn remove(id) -> i64`

  In these, the `i64` is 0 on success, -1 for not found, or the primary SQLite code. Each write function is one `begin`/`commit` transaction. `update` runs one `UPDATE` with `CASE WHEN ?` for each optional field, then reads the row back inside the same transaction.
- **Worker:** `fn list(out: Todo[>..]&) -> bool` and `fn get(id, t: Todo&) -> bool`, on `sqlite::local(path, Mode.QueryOnly)`.
- **`fn todo_json(out, t)`** writes the same shape as `/api/todos`.
- **`fn fail(res, code)`** applies the status mapping from Decision 3.

**The schema:**
- Step 0 creates the table:
  ```sql
  CREATE TABLE todos (id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL CHECK (length(CAST(title AS BLOB)) BETWEEN 1 AND 200),
    done INTEGER NOT NULL DEFAULT 0 CHECK (done IN (0, 1)))
  ```
- Step 1 inserts three seed rows: "Persist a todo", "Restart the server", "See it again".
- `AUTOINCREMENT` is there so that a deleted id never comes back as a different todo.

**`app/state.goose`:**
- **`Msg` gains `DbAdd { title: u8[..200] }`, `DbUpdate { … }` (the same fields as `Update`) and `DbRemove { id: i64 }`.** These shapes already exist, so `Msg` does not grow.
- **`Reply` becomes `{ ok: bool, db_code: i64 = 0, todos: Todo[] }`.** The existing literals compile unchanged.
- **`init` calls `todosdb::open()`.** If that fails, it prints the error and calls `exit(1)`.
- **`handle` converts `todosdb::Todo` into `state::Todo`.**

**Read-your-writes.** The owner commits before it replies. The worker's next statement starts a fresh WAL snapshot, so a POST followed by the page's `load` shows the new row.

**Rejected:**
- Replacing the in-memory todos: this breaks the `/api/todos` comparison with Next and `check_site`'s "exactly the three seeds".
- Reads through the owner: they serialize every read, which is what SQLite's WAL readers avoid.
- Writing to `shop.db`: Decision 2.

**Risks:**
- **Order with Addendum 7 (CSRF).** If Addendum 7 lands first, the `/db/todos` form and the `--writes` POSTs must carry whatever it requires, built exactly like `/fragments`.
- **`app.db` persists between runs**, so the checks must not assume its contents.

## Files and shared edit regions

**This addendum touches:**
- **goose-sqlite:** `sqlite.goose`, `src/sqlite.c`, `test/test_sqlite.goose`, `.gitignore` (one line, `test/*.db`), `README.md`, `CHANGELOG.md`.
- **lab, `examples/shop/`:**
  - changed: `app/state.goose`
  - new: `lib/todosdb.goose`, `app/api/db/todos/route.goose`, `app/api/db/todos/[id]/route.goose`, `app/db/todos/page.goose`, `app/db/todos/page.html`
- **lab root:** `.gitignore`, one line: `examples/shop/data/app.db*`.
- **lab, `goose-bench/shop/`:** `check_site.py` (in the regions below), plus a new `check_persist.py`.
- **goose-web:** `README.md` (in the region below), `CHANGELOG.md`, and this file.

**Shared files, exact regions:**
- **`web.goose`:** no edit.
- **goose-web `README.md`:** only the `## SQLite` section, which today runs from that heading to the line before `## Cookies`. Rewrite its last sentence: workers read with `local(path)`, or with `Mode.QueryOnly` for a database the app writes. Then append one paragraph, "Writes", of 6–8 lines: writes go on the owner through `sqlite::writer` in `state.goose`, with a pointer to `examples/shop/lib/todosdb.goose`.
- **`check_site.py`** has four insertions:
  - (a) One usage line after the `--fragments` usage line in the docstring.
  - (b) One paragraph, `--writes adds DESIGN-ADDENDUM-10: …`, after the `--fragments` paragraph.
  - (c) One line, `WRITES = "--writes" in sys.argv[1:]`, after the `FRAGMENTS = …` line.
  - (d) One self-contained `if WRITES:` block, directly before `print("bytes per URL:")`. If other addenda's blocks already sit there, add it after them.

  Do not edit the bytes-per-URL loop or any existing check.

**Kept off:** `form.goose`, `template.goose`, `client/gwi.js` (Addenda 7 and 9), `cli/gweb.goose` (Addendum 8), `owner.goose`, `src/owner.c`, and the products code.

## Builder plan (Sonnet 5.5, medium effort)

Common settings:
- `GOOSE=/Users/joeheinz/Documents/goose/goose-sdk/goose-v2026.4-macos-arm64/goose`. `LAB=/Users/joeheinz/Documents/goose`.
- One commit per step, in the repo that owns the files: goose-sqlite, goose-web, or the lab root for `examples/` and `goose-bench/`. Do not push.

**Code rules:**
- No comments that restate code, narrate history or cite this document. Only why-comments and one-line public API notes in the style of `sqlite.goose`.
- Keep the one-line function style of `sqlite.goose`.

**"Full suite"** means all of these:
- `test_sqlite` prints "all sqlite checks passed".
- From goose-web, with `GOOSE` set: `test/components.sh` 41, `test/templates.sh` 33, `test/fragments.sh` 69, `cookie_test` 59.
- goose-net `test_net` 142.
- `test/release_check.sh` passes.
- In `$LAB/examples/shop`: `../../goose-web/gweb build`, start `.gooseweb/server --port 3300`, then run `python3 $LAB/goose-bench/shop/check_site.py http://localhost:3300 --components --cookies --fragments` (plus `--writes` from step 2.4 on). It must print PASS, which includes `/products/42` against `baseline/products_42.html`.

### Phase 0: baseline and experiment (no commit)

**0.1 Baseline.**
1. Build the shop at the current HEAD and start it with `--workers 1`.
2. Run `$LAB/goose-bench/loadgen/loadgen 3300 <url> 64 50000 keepalive` 3 times each for `/api/todos`, `/db/products`, `/db/products/42`, `/api/db/products/42` and `/products/42`, after a warm-up of `loadgen 3300 <url> 16 5000`.
3. Record the median rps, then repeat the whole set once to learn the noise.
4. Run the full suite and record that it passes.

**0.2 Experiment E4: does a contained worker's abort run pthread TLS destructors?**
1. In the earlier prototype (`/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-sqlwrite/goose-sqlite-proto`, which has the destructor and the `GSQ_NO_CLEANUP` switch), write `exp/e4.goose`:
   - Main creates a WAL database with a `todos` table.
   - A `thread_spawn_contained` worker opens `sqlite::local(path, Mode.ReadWrite)`, calls `begin`, inserts a row, then calls `abort("boom")`.
   - Main calls `thread_wait(id, msg)`. On its own connection, with `set_busy_timeout(db, 300)`, it calls `begin`.
   - Print whether `begin` succeeded and the error code if not.
2. Run it with and without `GSQ_NO_CLEANUP=1`.

What each outcome means:
- **`begin` succeeds with cleanup and fails without:** do step 1.6.
- **It fails in both runs:** the runtime does not end the OS thread through pthread exit. Skip 1.6 and add the risk line from 1.6 to the goose-sqlite README.
- **It succeeds in both runs:** something else releases the lock. Report it to the architect before continuing.

### Phase 1: goose-sqlite (repo goose-sqlite)

Every step adds its named checks to `test/test_sqlite.goose`. The check after each step is `$GOOSE build test/test_sqlite.goose && test/test_sqlite`, which must print "all sqlite checks passed". Tests use their own files (`test/w.db` and similar) and delete them, with their `-wal` and `-shm`, before starting.

**1.1 Statement results and error codes.**
- C: `gsq_run`, `gsq_stmt_last_id`, `gsq_stmt_changes`, `gsq_code`, `gsq_busy_timeout`, as in the prototype.
- Goose: `run`, `insert`, `update`, `code`, `busy`, `constraint`, `set_busy_timeout`.
- Checks:
  - "insert id": first insert gives 1.
  - "update none": 0, true.
  - "update one": 1, true.
  - "run delete"
  - "unique fails": false.
  - "constraint code": `code == 2067` and `constraint` is true.
  - "constraint text": `error` contains "UNIQUE".
  - "failed prepare run": `run` on a failed `prepare` is false.

**1.2 Transactions.**
- `begin` (`BEGIN IMMEDIATE`), `commit`, and `rollback` (only when `sqlite3_get_autocommit` is 0).
- Checks:
  - "commit keeps"
  - "rollback discards"
  - "rollback idle": `code` is unchanged after a `rollback` with no transaction open.
  - "defer rollback after commit": a helper using the idiom from Decision 3 commits once.
  - "begin busy": connection A begins; B, with busy timeout 50, fails to begin and `busy(B)` is true.

**1.3 `Mode.QueryOnly`.**
- Mode code 3: `SQLITE_OPEN_READWRITE`, then `PRAGMA query_only=1`. On failure, close and fail the open with the error text.
- Checks:
  - "query_only rejects write": insert fails, `code & 255 == 8`.
  - Create a WAL file, close it, delete its `-wal` and `-shm`. Then:
    - "query_only reads wal without shm": `QueryOnly` succeeds.
    - "readonly fails wal without shm": a `ReadOnly` `prepare` fails. This records why the mode exists. If it unexpectedly passes, report it and keep the check inverted.
  - "threads see writes": main inserts 2,000 rows through a writer while 3 `QueryOnly` threads read in a loop, as in prototype E2d and E3. Expect 0 reader failures and that each reader saw the count change.

**1.4 `writer(path, durable)`.**
- An internal mode code for the cache; `READWRITE | CREATE`; the WAL check; `synchronous`, plus `fullfsync=1` when durable; busy timeout 1,000.
- The claim: a C mutex and a list of path and owning `pthread_t`. A failed claim sets the thread's `open_error`.
- Checks:
  - "writer wal": `PRAGMA journal_mode` gives `wal`.
  - "writer same thread": the same `h` twice.
  - "writer other thread": a spawned thread gets `!ok`, and `error` contains "writer".
  - "writer durable": `PRAGMA synchronous` gives 2.
- For information only: time 2,000 durable inserts and report the mean and max in the commit message.

**1.5 `version` and `migrate`.**
- As in the prototype. Confirm that a literal list compiles as `const u8[:][:]`. If it does not, use the nearest type that does, and report the compiler message.
- Checks:
  - "migrate fresh": version 2, 3 seed rows.
  - "migrate again": true, no new rows.
  - "migrate add step": version 3.
  - "migrate newer refused": 2 steps against version 3 gives false.
  - "migrate failure rolls back": a bad step 2 leaves version 2 and no partial table.

**1.6 Thread-exit cleanup (only if E4 said so).**
- A per-thread holder registered with `pthread_key_create`, whose destructor finalizes the statements and closes the connections. Keep a `__thread` fast path, and no environment switch.
- If the destructor closes a claimed writer, it must also drop the claim.
- Check "aborted worker releases lock": the E4 scenario, where `begin` on main succeeds within 300 ms.
- Re-run the Phase 0 baseline for `/db/products/42` only, and confirm it is within 3%.
- If skipped, add this risk line to the README instead: "A worker that aborts mid-statement or mid-transaction keeps its connection until the process exits."

**1.7 README and CHANGELOG.**
- README:
  - Add the new functions.
  - Add a "Writes" section: one writer per database through `writer` (claimed per thread), readers in `QueryOnly`, the transaction idiom, `migrate`, the error predicates, and NORMAL against durable.
  - Replace the `ReadOnly`/WAL bullet: `ReadOnly` is for databases nobody writes; use `QueryOnly` for a database the app writes.
- CHANGELOG: a `## v0.2.0 (unreleased)` entry.
- Check: the README example still compiles. Paste it into a scratch file and run `$GOOSE check`.

### Phase 2: the shop demo (lab repo)

After each step, run the full suite.

**2.1 `lib/todosdb.goose` and `app/state.goose`.**
- Write them as Decision 7 says, and add the `.gitignore` line.
- First experiment: build once with `state.goose` importing `lib.todosdb`. If gweb's copy of `state.goose` cannot resolve `lib.todosdb`, report the error and stop. Do not move the SQL into `state.goose` without an architect decision.
- Checks:
  - The full suite, without `--writes`.
  - `data/app.db` exists after start.
  - `sqlite3 data/app.db 'PRAGMA user_version'` gives 2, and `PRAGMA journal_mode` gives `wal`.
  - `/api/todos` is unchanged in check_site.

**2.2 `/api/db/todos` and `/api/db/todos/[id]`.**
- Routes as in Decision 7, using `todosdb::todo_json` and `todosdb::fail`, with the same 400 messages as `/api/todos`.
- Check by curl: POST gives 201 and an id; GET by id gives 200; PUT `{"done":true}` gives 200; DELETE gives 200 and `{"deleted":true}`; then GET gives 404, and `/api/db/todos/abc` gives 400.

**2.3 `/db/todos` page.**
- `page.goose` and `page.html`, copying the `/fragments` page's markup and POST handling. The title is "Saved todos"; the `{#fragment todo-list}` region is the same.
- Do not add a nav link.
- Checks:
  - The full suite.
  - `/products/42` is byte-identical.
  - The browser lines below, by hand.

**2.4 `check_site.py --writes` and `check_persist.py`.**

The `--writes` block, inside the regions above:
- Record the starting count of `/api/db/todos`.
- POST `{"title": "check <db>"}` gives 201, and the reply has `done` false.
- GET it; `/db/todos` contains `check &lt;db&gt;`.
- PUT `{"done": true}`; PUT `{"title": ""}` gives 400.
- DELETE gives `{"deleted":true}`; GET gives 404; a second DELETE gives 404.
- POST `{"title": ""}` gives 400.
- A fragment POST of `add=1&title=check+%3Cpage%3E` to `/db/todos` shows it escaped. Remove it through the form; it is gone.
- The final count equals the starting count.
- `/api/todos` still has exactly the three in-memory seeds.
- A cross-site POST to `/db/todos` is refused, the same as `/fragments`.

`check_persist.py` (new). Its argument is the shop folder. It:
1. Starts `.gooseweb/server --port 3301` with `SHOP_APP_DB` pointing into a fresh temporary folder.
2. POSTs `{"title": "survives"}`.
3. Kills the server with SIGKILL.
4. Checks that bytes 18–19 of the file header are `02 02` (WAL).
5. Restarts the server and GETs the id: 200 with "survives".
6. Checks `/api/db/todos` holds the 3 seed rows plus that one.
7. Stops the server and deletes the folder. It exits 1 on any failure and prints PASS otherwise.

Checks: the full suite with `--writes`, and `check_persist.py` prints PASS.

**2.5 Performance gate (no commit unless a fix is needed).**
- Repeat the Phase 0.1 measurements. Each URL must be within 3% of the baseline median.
- If one is not, re-run both sides once. If it still fails, report to the architect with the numbers. Do not tune.

### Phase 3: goose-web docs (repo goose-web)

**3.1 README `## SQLite` region and CHANGELOG.**
- README as given in "Files and shared edit regions".
- CHANGELOG: a `## v0.2.0 (unreleased)` line: "SQLite writes: the owner-thread writer pattern, documented, with the shop's `/db/todos` demo; needs goose-sqlite v0.2.0."
- Do not bump `VERSION`; the release step does that for all the addenda together.
- Check: `test/release_check.sh`, which publishes goose-sqlite from the working tree.

### Browser test lines (step 2.3, then after Phase 3)

1. Open `http://localhost:3300/db/todos`. You see "Saved todos" and the three seeds.
2. Add `buy <milk> & eggs`. It appears escaped, and only the list region updates (the network tab shows a fragment reply).
3. Click Done on it. It shows struck through, with an Undo button.
4. Reload the page. It is still there and still done.
5. Stop the server and start it again, then reload. It is still there.
6. Click Remove. It is gone; reload, and it is still gone.
7. Submit an empty title. You see the error, and nothing is added.
8. Open `/todos`. The in-memory list still shows its own three seeds, unaffected.
9. Open `/products/42` and `/db/products/42`. They look as before.

## Decisions for the user

1. **Durability default.** `synchronous=NORMAL` (chosen: commits survive a process crash, not power loss) or FULL by default.
2. **Demo shape.** A `/db/todos` twin, keeping the in-memory `/api/todos` for the Next comparison (chosen), or replacing the in-memory todos and dropping or redefining the STATE benchmark row.
3. **Start-up failure.** Exit when `app.db` cannot be opened or migrated (chosen), or serve with the database routes answering 503.
4. **The `writer()` claim.** Enforcing one writer thread per path per process (chosen) is opinionated. The alternative is documentation only.
5. **Write benchmarks.** Whether `bench_shop.py` gets write rows (the default here is no; loadgen is GET-only today).
6. **Generic write batch.** Deferred. Revisit when the CMS work starts.
7. **Landing order with Addendum 7.** Build Phase 2 after Addendum 7 if CSRF tokens become mandatory on page POSTs, or build it first and let Addendum 7 update `/db/todos` with `/fragments`.
