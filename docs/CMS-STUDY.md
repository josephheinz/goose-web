<!-- Produced by goose-architect on claude-fable-5-2 -->
# Study: a Goose CMS on goose-web and goose-sqlite

This is a study for the user to choose from; nothing is decided or implemented, and nothing outside the scratchpad was changed. It ends with four options, a comparison table and a recommendation.

## Rename mapping

I agree with the mapping (`components/`, `{{component Name(expr)}}`, `data-component`, `cli/component.goose`). One consequence for this study: "component" now means a `.gshtml` client component, so I call a CMS page-building unit a **block**, never a component.

## What I measured first

All on this Mac, system libsqlite3 3.54, in the scratchpad. Prototypes are listed at the end.

### SQLite: one writer plus per-worker readers, in one process

Table of 2,000 pages, each with a 4.6 KB pre-rendered HTML body; lookup by slug copies the body out.

| Setup | Reader lookup | Writer commit | Result |
|---|---:|---:|---|
| Rollback journal, read-only readers, 1 thread, no writer | 6.5 µs | n/a | works |
| Rollback journal, read-only readers, 4 threads, no writer | 15.3 µs | n/a | works |
| Rollback journal, 4 **read-only** readers + writer | 15 µs | fails | **199 of 200 writes fail** with `SQLITE_IOERR_LOCK` (extended code 3850) |
| Rollback journal, 4 readers opened read-write + writer (C test) | not timed | 1.6 ms mean | works |
| Rollback journal, writer alone | n/a | 0.4–0.6 ms | works |
| WAL, read-only readers, 1 thread | 4.3 µs | n/a | works once the writer has touched the database |
| WAL, 4 read-only readers + writer | 10.5 µs | 42 µs mean, 2 ms max | works; readers saw all 200 revisions |
| WAL, read-only readers opened before the writer's first statement (C test) | n/a | n/a | every reader fails: "unable to open database file" |
| WAL, readers opened read-write | not timed | 55 µs mean | works in any order |

- **Today's setup cannot take a writer.** Rollback journal with read-only worker connections is fine for a read-only site, but a read-write connection in the same process fails to lock. I reproduced it in plain C, so it is not goose-sqlite's doing.
- **WAL is the mode for a CMS.** Writes are about 10 times cheaper, readers never block, and each new request sees the last commit with no extra step.
- **The read-only WAL finding from DESIGN-ADDENDUM-2 Follow-up 1 still holds**, and narrows to an ordering rule: read-only readers work only after a writer in the process has initialised the `-shm` file.
- `PRAGMA query_only=1` on a read-write connection rejects writes ("attempt to write a readonly database"), checked with the `sqlite3` CLI.

### Change detection and caching

| Mechanism | Cost per check |
|---|---:|
| `PRAGMA data_version` on the worker's connection | 3.2 µs (and it does change after another connection's write) |
| A process-wide atomic counter in C, read through `extern fn` | 0.5 ns |
| Owner round trip (`state::ask`), from SUMMARY.md: `/api/todos` 0.134 vs `/api/health` 0.044 CPU s per 10k | about 9 µs |
| Per-worker dictionary hit plus 4.6 KB copy | 0.17 µs |

Goose has no shared mutable memory and no atomics (reference §22), so a cross-worker signal must live in C or in the database.

### Language and framework facts

- **Reflection is enough for typed content.** A 79-line prototype takes `struct Article { title: u8[..120], ..., featured: bool, weight: i64 }` and, with `const for <N, A> in fields<T>`, produces the `CREATE TABLE`, the `INSERT`, the `SELECT` into the struct, and an HTML form (`maxlength` from `.cap`, textarea above 200 bytes, checkbox for `bool`). Built and run.
- **A type registry works as a struct.** `struct Site { article: Article, person: Person }` iterated with `fields<Site>` lets one generic admin handler pick a type by a run-time string. Passing a `types<...>` list as a generic argument does not compile.
- **A rebuild is cheap.** `gweb build` of a copy of the shop (17 routes and pages) took 1.3 s; SUMMARY.md gives 6–20 ms to the first 200 after start.
- **No catch-all route.** `[...x]` was deferred in DESIGN.md §1. Each dynamic depth needs its own folder.
- **A root `app/[slug]/` shadows static files.** The generated dispatcher tries static files only when no route matched (`cli/gweb.goose`, around line 690), so `/favicon.ico` would reach the slug page.
- **Missing today:** cookies, a form-body parser (only `web::query` and `http::url_decode`), multipart, serving files from disk (`public/` is embedded at build), template partials, markdown, and any cryptographic hash or HMAC in the stdlib. `max_body` defaults to 1 MB. Loaders cannot set headers or cookies (DESIGN-ADDENDUM-1).
- **An abort on the main thread ends the program** (reference §22). The state owner is `main`.

## Content model

### How types are defined

| Way | Where the truth is | Rebuild on type change | Template type safety |
|---|---|---|---|
| Goose structs + reflection | `lib/content.goose` | yes, 1.3 s | full: `props.article.title` is checked |
| Schema file + gweb codegen | `content/schema` | yes | full, on generated structs |
| Rows describing fields | `cms_types`, `cms_fields` tables | no | none: `cms::text(entry, "title")`, a typo is an empty string |
| Markdown files with front matter | `content/**.md` | yes, and on every content change | full |

Data-driven types do not escape the compiler: templates are compiled, so a new type still needs a new template and a rebuild before the site can show it. Only the admin sees it at once.

### Fields, relations, rich text

- **Fields:** `i64`, `bool`, `f64`, `u8[..N]` map directly. The bound gives the maximum length for free.
- **Large text:** a `u8[..20000]` field makes every `Article` 20 KB. List pages should load a smaller struct (`ArticleCard`) whose field names are a subset; the generated `SELECT` already names columns from the struct. Verified for the full struct only.
- **Relations:** a single reference is an id. Reflection cannot tell an id from a number, so it needs a wrapper type (`cms::Ref<Author>`) or a `_id` naming rule; many-to-many needs one generic link table with a position column. Not prototyped.
- **Rich text:** store markdown and the HTML rendered from it at save time. Then a read is one lookup and no render. The renderer is either a C binding to a small library (about 80 lines plus the vendored C) or a Goose subset renderer (400–600 lines, estimate).
- **Raw HTML from a WYSIWYG editor** needs a sanitizer; I would not start there.

### Media

- Uploads cannot go to `public/`; they go to `data/media/` and need a disk-serving route with ETags (80–120 lines, estimate).
- Without multipart, an upload can be a small script sending the raw file with `PUT /admin/media/<name>`; the 1 MB body limit needs a per-route override.
- Image resizing is out of scope for every option.

### Slugs and routing

The dispatcher is compiled, so the route shape is fixed at build time and the slug is resolved by a query inside the loader.

| Route style | gweb change | Fits |
|---|---|---|
| R1: one folder per type, `app/blog/[slug]/page.goose` calls `cms::by_slug<Article>` | none | typed collections (posts, products, people) |
| R2: catch-all `app/[...path]/` for a page tree | new: catch-all segment, tried after static files (60–120 lines, estimate) | free-form pages such as `/about/team` |
| R3: folders generated from a schema | part of the codegen option | both |

- R2 must also fix the shadowing order above, and read `req.path` directly, since a param value is capped at 256 bytes.
- A slug change should write a row to a `redirects` table that the catch-all loader consults before answering 404.

## Admin editing

### UI

- **Server-rendered pages and plain forms** cover login, lists, edit, publish and delete. With reflection the edit form is generated; a hand-written `page.html` per type can override it.
- **Server fragments (option B)** fit best for: markdown preview, per-field validation messages, list filtering, and save without a full reload. All logic stays in Goose.
- **`.gshtml` components** fit widgets whose state is local: slug from title, character counters, a repeater for a list field, block ordering, a tag picker.
  - Limits that matter: state is flat with one growable list, handlers get no event data, components cannot call the server, and the DOM morph has no keys.
  - So a component hands its state to the server by rendering it into hidden inputs inside the page's form. I did not test a component inside a `<form>`.
  - Markdown preview cannot be a component: the client subset has no slices, char literals or `match`.

### Authentication: what the CMS needs from the cookie helpers

1. Read a cookie by name from `req`.
2. Set and delete a cookie from a route and from `before`/`after` middleware, with `HttpOnly`, `Secure`, `SameSite`, `Path` and `Max-Age`.
3. A flat slot in `Ctx` for the signed-in user (for example `user: i64, role: i64`), filled by `app/admin/middleware.goose` and readable by loaders and templates.
4. A session token source with at least 128 random bits. `os.random_seed()` returns 64 bits "for rng"; a C helper over `arc4random_buf` is safer.
5. A CSRF token helper for forms, and the fragment runtime must send it as a header.
6. Not from cookies, but needed with them: `web::form(req, name, out)` for url-encoded bodies.

- **Sessions:** opaque tokens in a `sessions` table. Signed cookies would need HMAC-SHA256, which the stdlib lacks.
- **Passwords:** need a C hash (PBKDF2 from CommonCrypto on macOS, another library on Linux). The smallest v1 is a single admin secret from the environment.
- Sliding expiry must happen in `after` middleware, because loaders cannot set cookies.

### Drafts and validation

- **Drafts as twin tables.** Each type gets `article` (published) and `article_draft` with the same generated columns. Publish copies the draft row, renders the HTML and commits, in one transaction. No serialization format to version.
- **History** is a third, append-only twin; leave it for later.
- **Preview** is an admin-only route that renders the same template from the draft table, and never reads a cache.
- **Scheduled publishing** can be a `publish_at <= now` filter in the read query, so it needs no background job.
- **Validation:** bounds come from the types. Required, unique slug, slug format and reference checks are a per-type `fn validate(a: const Article&, errs: cms::Errors&)`; a generic do-nothing overload is the default (the specific-over-generic overload pattern is what the prototype uses). The form re-renders with messages.

## Writes and concurrency

Three places a write can run:

| | W1: owner thread | W2: the worker handling the request | W3: a separate admin process |
|---|---|---|---|
| Connection | one read-write, opened in `init` | one read-write per worker, lazily | its own |
| Ordering | serialized by the owner loop | SQLite's write lock plus the 2 s busy timeout | SQLite's write lock |
| If the write code aborts | the whole server exits | one worker respawns; if it was mid-transaction, its leaked connection holds the write lock until restart | the admin process exits; the site keeps serving |
| Cost | about 9 µs per round trip, payload copied twice | none | cross-process change signal needed (`data_version`, 3.2 µs) |
| Fit | the pattern DESIGN-ADDENDUM-2 names | least code | strongest isolation, most deployment work |

- **Keeping W1 safe:** the worker parses and validates, then sends the owner a generic write batch (statement text plus bound values); the owner only binds, steps and commits. The owner then holds no code that handles user input, and stays content-type-agnostic (about 100 lines, estimate).
- **One state file:** `app/state.goose` is root-only with fixed names, so the CMS needs a variant in the app's `Msg`, or gweb must learn to compose state modules.
- **Journal mode: WAL**, set once by the writer in `init`, before workers spawn.
- **Reader connections:** add a reader mode to goose-sqlite that opens read-write and sets `PRAGMA query_only=1` (about 15 lines). Plain `ReadOnly` works only while the start-up ordering holds, and a respawned worker reopens later.
- **How readers see new content:** with no cache, the next request sees it; nothing to do. With a cache, see below.
- **Consequence for the shop benchmark:** none; it stays read-only on a rollback journal.

## Publishing and caching

Numbers from SUMMARY.md (one worker, 64 clients) and my lookup measurements:

| Strategy | Product-page-like route | List route (100 rows) | Cross-worker invalidation |
|---|---:|---:|---|
| Next dynamic, SQLite | 2,566 req/s | 782 | n/a |
| Next static (prerendered) | 13,171 | 4,730 | rebuild |
| goose, query on every request (measured: `/db/products/42`, `/db/products`) | 131,310; 7.4 µs CPU | 35,422; 28 µs CPU | none needed |
| goose, per-worker rendered-page cache (estimate from `/products/42` plus a 0.17 µs hit) | about 220,000, the loopback ceiling; about 4.7 µs CPU | about 220,000 | epoch counter |
| goose, static export embedded in the binary (measured: `/css/site.css`) | 220,484 | 220,484 | rebuild, 1.3 s or more |

- **No cache is already 10 times Next's static best case** and 51 times Next dynamic on a page, and scales to 118k–131k req/s on the list route at 4–6 workers.
- **A page cache buys about 1.6 times CPU on a single page and about 6 times on a list page.** It costs memory per worker: 9 MB per 2,000 pages of 4.6 KB, so about 37 MB at 4 workers.
- **Invalidation across workers:** a C atomic epoch in `src/sys.c` (10–20 lines), bumped after each commit; each worker compares it per request (0.5 ns) and clears its cache. `data_version` costs as much as the lookup it would save, so it defeats the cache.
- **Static export buys no speed over the cache here.** Its value is hosting with no server or database; its cost is a rebuild per publish and a larger binary.
- **A CMS page with a 4.6 KB stored body** should land near 9–10 µs CPU uncached (estimate: 4.5 µs base plus a 4.3–6.5 µs lookup), so roughly 100k req/s per worker.

## Where `.gshtml` components fit, and rebuilds

- **Admin:** editor widgets as listed above.
- **Public site:** a block list is rendered on the server by a Goose function with a `match` on block kind. An interactive block can embed a component, but only one named at compile time: `{{#if b.kind == "counter"}}{{component Counter(b.state)}}{{/if}}`.
- **Gap:** block markup wants template partials (a `.html` file compiled to a function). DESIGN.md §7 rejected them for v1; without them blocks are hand-written `format(out, ...)` calls. Estimate 100–150 lines in gweb.
- **Rebuild or not:** content never needs a rebuild in the SQLite options. Types, templates, blocks and components always do, at about 1.3 s plus a restart. There is no zero-downtime restart today.

## Options

Estimates are lines of Goose unless stated, and are estimates, not measurements.

**Shared prerequisites for A, B and C** (about 500–900 lines): form-body parser, cookies and sessions, CSRF, WAL writer path with the reader mode, markdown rendering, disk media route, and the catch-all route if R2 is wanted.

### Option A: code-first, typed structs with reflection

- Types are Goose structs in `lib/content.goose`, registered in one `Site` struct. A `cms` library generates tables, queries and admin forms through reflection.
- Routes are written by hand (R1), with R2 added for a free-form page type.
- Admin is server-rendered, generated per type, and can be overridden.
- **Effort:** `cms` library 500–800, admin 400–600; with prerequisites about 1,400–2,300.
- **Scope-creep risks:** migrations when a field is renamed or removed (adding a column is easy; the rest needs rules); relations beyond single references.

### Option B: schema file with gweb codegen

- A `content/schema` file; gweb generates structs, tables, admin pages and route folders (R3).
- **Buys over A:** generated routes, field metadata that types cannot carry (labels, help text, required, reference targets), and a migration diff.
- **Effort:** A plus a schema parser and generators, 800–1,200 more; about 2,200–3,500 in all.
- **Scope-creep risks:** the schema language grows into a second language; gweb gains a second code generator the size of the component compiler's front end.

### Option C: data-driven types in tables

- Types and fields are rows; editors add types in the admin; values live in a generic store (one row per field value, or a JSON column).
- **Buys:** no rebuild to add a type or field in the admin.
- **Costs:** untyped templates, validation at run time, slower reads (several rows or JSON parsing per entry), and a rebuild is still needed to show a new type.
- **Effort:** 1,200–1,800 for the model and dynamic forms, 500–700 admin; about 2,200–3,400 in all.
- **Scope-creep risks:** highest. This is the road to a general-purpose CMS product: type editor, field plug-ins, a query language for templates.

### Option D: content files, no database, no admin

- Markdown with front matter in `content/`; gweb embeds and indexes it at build; publish is commit and rebuild.
- **Buys:** fastest path (every page at the 220k ceiling), no auth, no writes, no forms, history from git.
- **Costs:** only developers can edit; every content change is a deploy.
- **Effort:** 500–900, including the markdown renderer.
- **Scope-creep risks:** low; the pressure is the later request for an editing UI, which leads to A anyway.

## Comparison

| | A: typed structs | B: schema codegen | C: data-driven | D: files |
|---|---|---|---|---|
| Type definition | Goose structs | schema file | table rows | front matter |
| Rebuild for a new type | yes (1.3 s) | yes | admin no, site yes | yes |
| Rebuild for content | no | no | no | yes |
| Template type safety | full | full | none | full |
| Editors without a developer | content only | content only | content and types | no |
| Admin UI | generated by reflection | generated by gweb | dynamic | none |
| Writes, auth, cookies needed | yes | yes | yes | no |
| gweb changes | catch-all (optional), partials (optional) | large | catch-all | medium |
| Read cost per page | 1 query | 1 query | several, or JSON parsing | none |
| Effort (lines, estimate) | 1,400–2,300 | 2,200–3,500 | 2,200–3,400 | 500–900 |
| Scope-creep risk | moderate | moderate to high | high | low |

Scope-creep risks common to A, B and C: a page builder, WYSIWYG editing, roles and workflow, localization, image processing, revision diffs, search, multi-site, and a headless API. Each is a project of its own; none belongs in a v1.

## Recommendation (for the user to accept or reject)

**Option A, built in phases, with writes on the owner thread (W1) under WAL, and no page cache at first.**

- **Why A:** it matches what goose-web is: compiled, typed, and fast. The prototype shows reflection does the tedious part in under 100 lines, and a 1.3 s rebuild makes "types need a rebuild" a small price.
- **Why W1 with a write batch:** it is the pattern DESIGN-ADDENDUM-2 already names, writes are serialized without busy handling, and keeping input handling on the worker removes the one serious risk (an abort on `main`).
- **Why no cache yet:** the uncached route already runs 10 times Next's static best case. Add the epoch counter and a per-worker cache only when a real site's list pages show the need.
- **Phase 1:** prerequisites, the `cms` library, hand-written routes (R1), generated admin with plain forms, a single admin secret, twin-table drafts, preview.
- **Phase 2:** catch-all pages (R2) with the static-file order fix, markdown preview and inline validation through fragments (option B of CLIENT-OPTIONS), media, password accounts.
- **Phase 3, each only on demand:** the cache, blocks with template partials, history.
- **I would not start C.** It gives up the type checking that is the reason to use Goose, and still needs rebuilds.
- **D is a sound smaller choice** if only developers will edit; its read API can be shaped so that moving to A later changes the loader, not the templates.

Decisions that are the user's: who edits (developers only points to D); whether editors must create types without a developer (the only reason for C); and whether W1's single `state.goose` constraint is acceptable or W2 is preferred for less code.

**Required whichever option with writes is chosen:** the move from rollback journal to WAL for any app that writes, since the current read-only worker connections make an in-process writer fail.

## Not verified

- Components inside a `<form>`, `cms::Ref<T>` as a field type, and subset structs for list queries.
- The W1 write batch, the reader mode, the catch-all route and the epoch counter inside goose-web itself; each was measured or checked only in isolation.
- WAL behaviour on Linux, and with a worker respawned after an abort.
- All line counts.

## Files

Prototypes, all under `/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-cms/`:

- `/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-cms/p1/p1.goose` — readers and writer through goose-sqlite, `data_version`, epoch and dictionary-cache timings
- `/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-cms/p1/p2.goose` — the same with write error messages
- `/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-cms/c/w.c` — the C reproduction of `SQLITE_IOERR_LOCK` and the WAL ordering failure
- `/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-cms/epoch/` — the C atomic counter package
- `/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-cms/r/r.goose` — struct to table, insert, select and form by reflection
- `/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-cms/r/t.goose` — the registry struct and run-time type selection
- `/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-cms/shopcopy/` — the shop copy used to time `gweb build`

Code and documents read: `/Users/joeheinz/Documents/goose/goose-web/web.goose`, `owner.goose`, `static.goose`, `template.goose`, `cli/gweb.goose` (dispatcher generator), `README.md`, `DESIGN.md`, `DESIGN-ADDENDUM-1.md`, `DESIGN-ADDENDUM-2.md`, `CLIENT-OPTIONS.md`; `/Users/joeheinz/Documents/goose/goose-sqlite/sqlite.goose` and `src/sqlite.c`; `/Users/joeheinz/Documents/goose/goose-bench/results/shop/SUMMARY.md`; and the Goose reference (§22 threads, `const for`), stdlib and packages docs. I read only the outlines of `DESIGN-ADDENDUM-3.md` and `GSHTML-STUDY.md`; the component limits above come from the README's implementation notes.
