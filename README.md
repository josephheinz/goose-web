# gweb

A Next.js-like web framework for [Goose](https://aardappel.github.io/goose/), on
[goose-net](https://github.com/josephheinz/goose-net). Folders under `app/` are routes. `gweb` turns the
project into one native binary that serves on every core.

Short guides are in [docs/site/](docs/site/).

## Install

```
git clone --branch v1.0.0 --depth 1 https://github.com/josephheinz/gweb
cd gweb && goose build -o gweb cli/gweb.goose
ln -s "$PWD/gweb" ~/bin/gweb           # or: cp gweb ~/bin/
```

```
gweb new mysite && cd mysite
GOOSE=/path/to/goose gweb dev          # http://localhost:60053, rebuilds and restarts on every change
```

A linked `gweb` uses its checkout as the gweb package, and a `goose-net` or
`goose-sqlite` checkout beside it. A copied `gweb` declares the tagged
releases from GitHub, and the compiler fetches them on the first build.
`gweb version` prints the version and the three sources it declares.
Set `GWEB_SRC`, `GWEB_NET` or `GWEB_SQLITE` to a path or a git source with
`@ref` to override one.

To run this package's tests from a clone, clone goose-net beside it
(`../goose-net`).

## Use the libraries without gweb

```goose
import gweb from "josephheinz/gweb@v1.0.0";
import net from "josephheinz/goose-net@v1.0.0";           // gweb needs this line too
import sqlite from "josephheinz/goose-sqlite@v1.0.0";     // only if you use SQLite
```

The design is in [DESIGN.md](docs/DESIGN.md). [DESIGN-ADDENDUM-1.md](docs/DESIGN-ADDENDUM-1.md)
replaces its handler API (section 4). [DESIGN-ADDENDUM-2.md](docs/DESIGN-ADDENDUM-2.md)
sets the worker default, the accept rules and SQLite. All came from the
goose-architect agent.

## Project layout

| File | Meaning |
|---|---|
| `app/**/route.goose` | API endpoint: `fn GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS` |
| `app/**/page.html` | Server-rendered page (template) |
| `app/**/page.goose` | Optional: `Props`, `fn load`, `fn POST` (needs `load`), helpers for the page beside it |
| `app/**/layout.html` | Wraps every page at or below its folder; `@slot()` marks the page |
| `app/**/middleware.goose` | `fn before` and/or `fn after` for the subtree |
| `app/not-found.html` | The 404 page, inside the root layout |
| `app/**/error.html` | Error page for the pages below it; the nearest wins; sees `err: gweb::ErrorInfo` |
| `app/**/loading.html` | Shown by `gwi.js` while a fragment request is slow |
| `app/state.goose` | State owned by the main thread: `Msg`, `Reply`, `fn handle`, optional `fn init`; `const VARIABLE_MSG = true;` when `Msg` has a variable-size payload such as `u8[]` (then `fn handle(m: const Msg..&)`) |
| `app/sitemap.goose` | Turns on `/sitemap.xml` and `/robots.txt`; optional `fn entries` and `fn robots` |
| `app/socket.goose` | Optional `fn open`, `fn message`, `fn close` for WebSocket connections |
| `app/jobs.goose` | Background jobs: `enum Job`, `fn run`, optional `fn schedule` |
| `app/config.goose` | Optional `fn check() -> bool`, run before the server listens |
| `stores/<Name>.gshtml` | A shared client store for components (see Components) |
| `gweb.packages` | The packages this project uses, one source per line, `at /prefix` to mount (see Packages) |
| `gweb.package` | In a package: `name IDENT` and `gweb VERSION`, the lowest gweb it needs (`gweb 1.0` accepts any 1.x) |
| `views/<group>/<Name>.goose` and `.html` | A view: `struct Props` and its template; gweb generates a JSON codec, an admin form and a by-name registry (see Views) |
| `lib/**.goose` | Your modules: `import lib.catalog;` (write their `namespace`) |
| `public/**` | Static files, embedded in the binary, with ETags and hashed URLs |
| `tests/*.goose` | Route tests run by `gweb test` (see Route tests) |
| `locales/default`, `locales/<tag>.txt` | Message catalogs, compiled to the `t::` module (see i18n) |

A folder named `[id]` is a dynamic segment; `[...slug]` and `[[...slug]]` are
catch-alls (see below). Folders starting with `_` are ignored. App files get their
namespace from `gweb`; do not write one.

## Signatures

Every function gweb calls in your code. These names and signatures are stable (see [stability](docs/site/stability.md)).
Write the ones you need; each is optional unless its file says otherwise.

```goose
// app/**/route.goose: any of the seven methods
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&)          // also POST, PUT, PATCH, DELETE, HEAD, OPTIONS

// app/**/page.goose
fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props                      // Props is yours; the template reads it
fn POST(req: const http::Request&, ctx: gweb::Ctx&) -> Props                      // needs load (fragments and forms)
fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) -> Props   // either page fn may take res; gweb::done(ctx) then keeps what it wrote
fn static_paths() -> u8[..1024][>..]                                              // for gweb export, on a page with a dynamic segment

// app/**/middleware.goose
fn before(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) -> bool   // false: res is final
fn after(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&)

// app/state.goose: Msg and Reply are yours
fn init()                                                                         // before the workers start
fn handle(msg: const Msg&) -> Reply                                               // const Msg..& when const VARIABLE_MSG = true;
fn shutdown()                                                                     // after the drain, before exit

// app/jobs.goose: Job is yours
fn run(job: const Job&, ctx: gweb::Ctx&) -> bool                                  // false: retried with backoff
fn schedule(s: gweb::Schedules&)

// app/config.goose
fn check() -> bool                                                                // false: the server exits 2 before it listens

// app/sitemap.goose
fn entries(req: const http::Request&, ctx: gweb::Ctx&, s: gweb::Sitemap&)
fn robots(req: const http::Request&, ctx: gweb::Ctx&, out: u8[>..]&)

// app/socket.goose
fn open(ctx: gweb::Ctx&, id: u64, topic: const u8[:])
fn message(ctx: gweb::Ctx&, id: u64, topic: const u8[:], data: const u8[:], binary: bool)
fn close(ctx: gweb::Ctx&, id: u64, topic: const u8[:])

// views/<group>/<Name>.goose
fn validate(p: const Props&, errs: gweb::FieldErrors&)
```

Helpers: `gweb::param(ctx, "id")`, `gweb::param_int`, `gweb::query(req, "q", out)`,
`gweb::html(res, status)`, `gweb::json(res, status)`, `gweb::not_found(ctx)`,
`gweb::redirect(ctx, "/to", 302)`, and `state::ask(ctx, state::Msg.List) -> Reply, bool`.
Set `ctx.title` in `load`; layouts read it.

## Catch-all routes

| Folder | Matches | Example under `app/docs/` |
|---|---|---|
| `[...name]` | 1 or more trailing segments | `/docs/a` and `/docs/a/b`, not `/docs` |
| `[[...name]]` | 0 or more trailing segments | `/docs`, `/docs/a` and `/docs/a/b` |

`gweb::param(ctx, "name")` returns the tail as it appeared in the path, joined with `/`
and not decoded: `a/b%20c/d`. It is `""` when an optional catch-all matched no segment.
`gweb::path_decode(out, tail)` appends the decoded text to a `u8[>..]` and returns false
for anything the router already refuses, so it cannot fail on a matched tail. Split the
tail with `split(gweb::param(ctx, "name"), '/')`.

```goose
fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    var path: u8[>..] = [];
    gweb::path_decode(path, gweb::param(ctx, "path"));
    ...
}
```

Rules:
- `public/` files are tried first for GET and HEAD, so a public file wins over `[id]`
  and catch-all routes. Then the routes with the same number of folders or a catch-all
  that fits are ranked per segment: a literal folder, then `[id]`, then a catch-all.
- The first route whose literal folders match wins. If it refuses a value, the answer is
  404; the next route is not tried. `/blog/<300 bytes>` is a 404 from `blog/[id]`, not a
  catch-all hit.
- A catch-all folder is the last folder of its route and holds no folder of its own. A
  folder holds one catch-all at most. `[[...name]]` cannot sit beside a `page.html` or
  `route.goose` in its parent, which would answer the same URL. Its name must differ from the
  `[id]` names above it. A route is at most 16 folders deep.
- The tail is at most 1,024 bytes, with any number of segments.
- The answer is 404 when the tail has an empty segment, a `.` or `..` segment (also
  percent-encoded), a `%2F` or `%5C`, a raw `\`, a control byte, or a malformed `%`. A
  trailing slash on GET or HEAD redirects with 308 first.
- A `[id]` value gets none of these checks. Decoded, it can hold `..`, so never join it
  to a file path without checking it.
- `gw-target` links to a catch-all page are checked at build time by the shape of their
  URL: `/docs`, `/docs/a/b` and `/docs/{p.slug}` all resolve to `app/docs/[[...path]]`.

## Templates

| Syntax | Does |
|---|---|
| `{expr}` | writes the value, HTML-escaped |
| `{#raw expr}` | writes it raw |
| `{#if e}` `{#else if e}` `{#else}` `{/if}` | conditions |
| `{#for x in e}`, `{#for x, i in e}`, `{/for}` | loops |
| `{#let n = e}` | a local |
| `@f(a)`, `@ns::f(a)`, `@f()` | calls `f(out, a)` |
| `@Name(expr)` | a component (a capitalized name with no `::`) |
| `@slot()` | the page, in a layout |
| `{-- note --}` | a comment |

Expressions are Goose. In scope: `req`, `ctx`, `props` (when `load` exists)
and everything `page.goose` imports. A tag stays on one line, and each HTML
line compiles to one Goose line, so compiler errors point at the HTML line.

**Literal braces and `@`.** Every `{` outside `<script>` and `<style>` opens a
tag, and a `}` without a `{` is an error. Write a literal brace as `&#123;` or
`&#125;`, and a literal `@` before `name(` as `&#64;`. Entities work in text and
in attribute values (so `onclick="if (x) &#123; f() &#125;"` and
`data-x='&#123;"a":1&#125;'`). `@` starts a call only when a path and `(` follow
it at once: `@user`, `joe@example.com`, `@ (x)` and `$38.61` are plain text.
Inside `<script>` and `<style>` elements nothing is a tag or a call: the text
passes through unchanged up to `</script` or `</style`, so inline CSS, JS and
JSON-LD need no escaping. `{x}` escapes for HTML, which is wrong inside a script,
so a server value there is not interpolated; write the whole element from a
function (`@shop::boot_json(props)`). The element's own opening tag is markup, so
`<script src="{props.url}">` works. The old `{{ }}` syntax is an error that
names its replacement.

## Components

A component is part of a page that runs in the browser, written in a subset of
Goose (Addendum 3 E1-E8; reactivity in [Addendum 12](docs/DESIGN-ADDENDUM-12-REACTIVITY.md)).
`components/Name.gshtml` at the project root (flat; `Name` is `[A-Z][A-Za-z0-9]*`).
The script comes first; the markup follows.

```
<script goose>
@prop const start: i64;
@prop const label: u8[:];
@prop const step: i64 = 1;
@state var count: i64 = start;
@computed let doubled: i64 = count * 2;
@watch { log(label, count); }
fn inc() { count += step; }
fn test_inc() { inc(); inc(); }
</script>
<button on:click="inc">{label}: {count} x 2 = {doubled}</button>
```

A page calls it with named props: `@Counter(start: 3, label: p.name)`. A prop with a
default may be left out; any other is an error (`@Counter needs prop start`).

| Declaration | Meaning |
|---|---|
| `@prop const x: T;` or `= LITERAL;` | input from the parent, read-only. `i64`, `bool`, `u8[:]`, `u8[..N]`, a struct, `S[:]` |
| `@state var x: T = e;` | local state; handlers assign it. `i64`, `bool`, `u8[..N]`, a struct, one `S[>..<]` (initializer `[]`) |
| `@computed let x: T = e;` | derived; the framework keeps it current; code cannot assign it |
| `@watch { }` | runs after the DOM updates, when state it reads changed |
| `@mount { }`, `@unmount { }`, `@every(MS) { }` | lifecycle |
| `@event fn name(params);` | an event for the parent |
| `@use Store;` | read a shared store |

- Types are required (`@state count needs a type`). The keyword is checked: `@prop` should be `const`,
  `@state` `var`, `@computed` `let` (warnings, errors under `--strict`).
- A component has at most 31 `@prop`, `@state` and `@computed` names. Names starting with `gw_` are reserved.
  A parameter or local cannot reuse a reactive name.
- Handlers are plain functions: `fn add(id: i64)`. Parameters are `i64`, `bool` or `const u8[:]`.
  Tests are `fn test_*()` with no parameters; props are zero in tests.
- Markup names state directly: `{count}`, `{#for t in items}`. `{#if}`, `{#for}`, `{#raw}`, `{#let}`
  and `{ }` work as in `page.html`; `@slot()` and `@f()` do not.
- gweb works out at build time which parts of the markup read which names. After a handler runs,
  only those parts update: a text node, an element's attributes, or (inside `{#if}` and `{#for}`) one
  block through keyed morph. Give list items `gw-key`, or the build warns `unkeyed-for`.
- If a handler throws, the state goes back and the page is untouched. A `{e}` directly in `<textarea>` is
  an error; use `bind:value`.

**Events.** `on:EVENT="handler"` or `on:click="remove(t.id)"` (arguments are `i64`, `bool` or strings).
Events: `click`, `dblclick`, `change`, `input`, `submit`, `keydown`, `keyup`, `focus`, `blur`; another
name warns `unknown-event`. Modifiers follow the event: `on:keydown.enter.prevent="add"`. They are
`prevent`, `stop`, a debounce `300ms` (1 to 10000; a bind still updates at once) and, on `keydown` and
`keyup`, `enter`, `escape`, `space`, `tab`, `up`, `down`, `left`, `right`, `backspace`, `delete`.
`bind:value="x"` and `bind:checked="x"` tie an input to a `@state` name. Modifiers load `/_gw/gwm.js`.

**Fetch.** In a handler: `x = await http::get(url);`, `let r: T = await http::get(url);`,
`await http::post(url, value);` or `x = await http::post(url, value);`. `await` goes only there and before
calls of async functions, never in markup, a computed or an initializer. The reply is checked against the
type of `x` or `r` (`i64`, `bool`, `u8[..N]`, a struct, `S[>..<]`). A refused status or a bad reply
(`bad reply from /api/items at [2].title`) restores what that handler wrote, so an optimistic `push`
disappears, and raises `gw:error`. POST sends JSON with the page's `_csrf` field as `X-CSRF-Token`. A literal
url must match a `route.goose` with that method (`http::get: no route GET /api/x`). Routes answer with
`gweb::json(res, http::Status.Ok); Name::gw_json(res.body, items);` (`gw_json` takes a struct or a `S[:]`).
Loads `/_gw/gwh.js`.

**Lifecycle.** `@mount` runs once when the component starts in the browser, `@unmount` when its root leaves
the document (no `await`), `@every(MS)` every MS ms (16 or more) while mounted. A component with any of
these, `@watch` or `@use` starts at load and runs its watches once first (`/_gw/gwl.js`); others wait for
their first event.

**Child components.** `@Card(title: it.name, n: count + 1, key: it.id)` inside a component. Props are `i64`,
`bool` or text. `key:` sets `gw-key` on the child's root; in a `{#for}` without it, `child-key` warns. A
parent update hands changed props to the live child, which keeps its own state (`/_gw/gwc.js`). The root is a
`<div>`, so a call cannot sit inside `<p>`. A component cannot contain itself.

**Child events.** The child declares `@event fn change(v: i64);` (params `i64`, `bool`, `const u8[:]`) and calls
`change(qty);` from a handler or lifecycle block. The parent listens: `@Qty(start: 1, on:change="picked")`;
`picked` is its function with the same parameters.

**Stores.** `stores/Cart.gshtml` holds one `<script goose>` block (no markup) of `@state`, `@computed`, structs
and functions; `@store(local: "cart")` first in it also keeps the state in `localStorage`. A component writes
`@use Cart;`, reads `Cart::count` (`i64`, `bool` or `u8[..N]`; each takes one of its 31 names) and calls
`Cart::add(id)` from a handler (a function that changes state and returns nothing). Components cannot assign
store values. Every component that uses the store follows the same state (`/_gw/Cart.js`, `/_gw/gws.js`). A
store has no `@prop`, `@watch`, `@mount`, `@unmount`, `@every`, `@event`, `@use` or `await`, and its name
differs from every component's.

**Legacy components.** A script with `struct State` instead of `@` declarations still works, calls
`@Name(expr)` with one `Name::State` value, and re-renders the whole component on each event. Port them with
Addendum 12 section 10; both styles in one file is an error.

**Output.** `.gweb/Name.goose` keeps the source's lines, so compiler errors point at the `.gshtml`.
`.gweb/_gw/Name.js` is the browser module: pretty under `gweb dev` (real names, a
`// components/Name.gshtml:LINE` comment above each function), compact under `gweb build` and `gweb start`.
The page gets the server render, the state as JSON, and `<script type="module" src="/_gw/Name.js">`. The core
runtime is `client/gwi.js` in dev and `client/gwi.min.js` otherwise; optional modules (`gwf`, `gwh`, `gwl`,
`gwm`, `gwc`, `gwn`, `gws`, `gwt`, `gwe`) are served only when a site uses them. All sit at `/_gw/` with ETags.

**Client subset.** The script leaves out `match`, `enum`, floats, `loop`, `guard`, `defer`, blocks, closures,
slices, `as`, bitwise operators, char literals, generics, globals and imports. Callable: the block's functions,
`min`, `max`, `abs`, `str`, `gweb::has`, `push`, `remove_at`, `clear`, `append`, `.len`. gweb reports anything
else as `components/Name.gshtml:LINE: error:`.

**`gweb test`.** Runs each `test_*` function (and a zero case) as Goose and as JavaScript, pretty and compact,
and compares the state and the render byte for byte. Needs `node`. It generates into `.gweb.test/`, so a
built `.gweb/server` and a running `gweb dev` are untouched.

**Tests of this package.** `test/components.sh` (parity fixtures in `test/components/`, `Fail*` per error,
`Warn*` per warning), `test/runtime.sh` (minified modules are current and under their size ceilings, then the
jsdom suites: `test/morph.sh`, `test/reactive.sh`, navigation, transitions, server push). jsdom installs into
`~/.cache/gweb-test` on first run.

**Maintainers.** After editing a `client/gw*.js` file, run `client/build.sh` (esbuild 0.28.2 through `npx`, or
`ESBUILD=/path/to/esbuild`); it writes `gw*.min.js` with the source's FNV-1a hash in its banner.

**Limits.** A moved keyed element is reinserted, which reloads an iframe inside it. Integers above 2^53 lose
precision in the browser. Component state lives in the page only. Handlers get no event data. See
[ARCHITECTURE.md](docs/ARCHITECTURE.md) section 7.

## Commands

```
gweb [-C dir] new <dir>      a starter project
gweb gen                     write .gweb/ only
gweb build [--debug]         gen, then goose build to .gweb/server
gweb start [flags]           build and run; the server flags below
gweb export [-o DIR]         build, then write the site as static files to DIR (default out/)
gweb dev [flags]             build, run on 127.0.0.1:60053 with 2 workers and the access log, rebuild on change
gweb routes                  the route table (GET,POST and a frag line for each fragment)
gweb test                    component parity (test_* as Goose and JavaScript), then tests/*.goose route tests (writes .gweb.test/; leaves .gweb/ alone)
gweb check                   goose check on a copy of the site; errors name .gshtml and page.html lines
gweb lsp                     language server for .gshtml and templates (needs node)
gweb version                 the gweb version and the package sources it declares (also gweb --version)
gweb help                    the usage (also gweb --help, gweb -h and gweb COMMAND --help); exit 0
```

`gweb dev` listens on `127.0.0.1`, because its overlay, `/__gweb/id` and the dev secret are not for a network.
`gweb dev --host 0.0.0.0` (or `GWEB_HOST=0.0.0.0`) opens it. `start` and the server keep `0.0.0.0`, which a container needs.

**Server flags** (`gweb start`, `.gweb/server`; the whole table is in [docs/DEPLOY.md](docs/DEPLOY.md)). Every one has a
`GWEB_*` variable of the same name (`--max-body` is `GWEB_MAX_BODY`), and a flag beats the variable. A value that does not
parse, or is out of range, stops the server with exit status 2 and a message that names it. Booleans take `1/0`,
`true/false`, `yes/no`, `on/off` and are written `--metrics`, `--no-metrics` or `--metrics=off`.

```
--port N              1 to 65535 (3000; PORT is an alias of GWEB_PORT)
--host H              the address to listen on (0.0.0.0; gweb dev 127.0.0.1)
--workers N           worker threads
--access-log          the access log, with X-Request-Id
--idle-ms N, --max-body N, --max-upload N, --upload-dir D
--max-upload-parts N, --max-upload-files N, --max-upload-text N     multipart limits (64, 8 up to 16, 65536)
--csp[=report-only|off], --trust-proxy, --security-headers, --hsts N
--session-idle N, --session-max N
--drain-ms N          drain time after SIGTERM before connections are cut (10000; dev 200)
--drain-delay-ms N    keep accepting this long after SIGTERM while /__gweb/ready says 503 (0)
--log-format text|json, --log-level debug|info|warn|error
--metrics             serve Prometheus text at /__gweb/metrics
--job-runners N, --job-queue N, --job-attempts N   background jobs (1, 10000, 5)
--no-schedule         run jobs, fire no schedules (GWEB_SCHEDULE=0)
--probe               GET /__gweb/ready on --port, exit 0 on 200 (the Docker HEALTHCHECK)
```

`--export DIR` and `--dev-id N` are flags only: `gweb export` and `gweb dev` use them. `GWEB_SECRET` and `GWEB_ENV` are
variables only. `--help` on the server prints the list.

The build prints warnings and goes on; `gweb dev` shows them in a small box at the bottom right.
`gen`, `build`, `start` and `test` take `--strict`: any warning fails the run (`gweb: --strict: 2 warnings stop the build`).
They also take `--diagnostics json`: stderr becomes JSON Lines, one `{"severity","file","line","code","message"}` object per diagnostic, plus `"detail"` for extra compiler lines.

Warning codes:

| Code | When |
|---|---|
| `prop-keyword`, `state-keyword`, `computed-keyword` | `@prop` should be `const`, `@state` `var`, `@computed` `let` |
| `unknown-event` | `on:EVENT` outside the known events |
| `unknown-attribute` | an attribute not in the HTML lists (`cli/html.goose`; `data-*`, `aria-*`, `gw-*`, custom elements and `<svg>` pass), or `onclick=` in a component |
| `unkeyed-for` | `{#for}` over a list that can reorder or shrink, without `gw-key` |
| `child-key` | a component call in `{#for}` without `key:` |
| `computed-no-state`, `watch-no-state` | `@computed` or `@watch` that reads no state |
| `state-unused` | a `@state` nothing reads |

`gweb` finds the compiler in `$GOOSE`, else `goose` on `PATH`, and finds this
package beside its own binary (or `$GWEB_HOME`). A checkout older than
the binary, or newer, stops with "rebuild gweb". Build `gweb` with:

```
goose build -o gweb cli/gweb.goose
```

## Views

A view is a typed, named piece of a page: a struct of props and a template. Code owns the shape. gweb generates a
JSON codec, an admin form, a form parser and a registry that renders a view by a name read at run time. The
`goose-cms` page builder uses views for page types, sections, widgets and layouts; nothing here knows about a CMS.

```
views/<group>/<Name>.goose    struct Props, optional fn validate, optional let LABEL / ICON / UI / RENAMED
views/<group>/<Name>.html     template; props, req, ctx, doc and at in scope; may use @slot("x")
```

`<group>` is `[a-z][a-z0-9_]*` and `<Name>` is `[A-Z][A-Za-z0-9]*`. A package's `views/` joins the project's;
a name that two sources define in one group is a build error. The namespace is `v_<group>_<Name>`.

```goose
// views/widgets/Hero.goose
import std;
import gweb;
import lib.link;                                          // a foreign type, below

let LABEL = "Hero banner";
let ICON = "image";
let UI = [gweb::FieldUi { field: "title", label: "Headline", help: "Up to 60 characters." }];
let RENAMED = [gweb::Renamed { from: "heading", to: "title" }];

enum Align { Left, Center, Right }
struct Cta { label: u8[..30] = "", url: u8[..200] = "/", align: Align = Align.Left }
struct Props {
    title: u8[..60],                                      // no default: required
    count: i64 = 3,
    badge: Badge,                                         // a struct of this file: a fieldset
    more: link::Link = link::Link { .. },                 // a foreign type
    ctas: Cta[>..<],                                      // a repeater: the last field
}
fn validate(p: const Props&, errs: gweb::FieldErrors&) { gweb::check_length(errs, "title", p.title, 2, 60); }
```

**Props fields.** `i64`, `bool`, `u8[..N]` (N a number), an enum with no payloads, a struct declared in the same file
(items hold scalars, enums and foreign types only), a repeater (`T[>..<]`, `T[>..]` or `T[..N]` of such a struct) as the
**last** field, and a foreign type `ns::T`. No `f64`. Anything else is a build error at the field's line. A field with no
`= default` is required. `UI`, `LABEL`, `ICON` and `RENAMED` take string literals; each `field:` must name a real field
(`"group.field"` reaches into a struct). A missing label comes from the name (`cta_text` is "Cta text", `TwoColumn` is
"Two column").

**Foreign types.** For `x: ns::T`, the generated code calls these, found by the type of `T`. Write them beside `T`:

```goose
fn gw_read(r: json::Reader&, v: T&, warn: i64&)
fn gw_write(out: u8[>..]&, v: const T&)
fn gw_field(out: u8[>..]&, name: const u8[:], v: const T&, label: const u8[:], help: const u8[:], editor: const u8[:], errs: const gweb::FieldErrors&)
fn gw_parse(req: const http::Request&, name: const u8[:], v: T&, errs: gweb::FieldErrors&) -> bool
```

**Slots.** `@slot("main")` and `@slot("left", "Hero Text")` (an allow list of view names) are holes in a view template.
Each compiles to `Z(out, req, ctx, doc, at, "left");`, where `Z` is a function you pass when you render. Layout views
(group `layouts`) may also use `@meta()` and get the page's module tags at their first slot.
A slot inside `<title>`, `<textarea>`, `<script>` or `<style>` is a build error at its line (1.1): there it would
be text, not a hole. The same holds for `@slot()` in `layout.html`.

**Generated, in the view's namespace:** `fn read(json, p: Props&) -> i64` (the warning count), `fn write(out, p)`,
`fn defaults(out)`, `fn form(out, json, errs, prefix)`, `fn form_req(out, req, json, errs, prefix)`, `fn parse(req, prefix, out, errs) -> bool` and
`fn render<Z, D>(out, req, ctx, props, doc, at)`. Do not define those names.

**Generated, in the module `views`** (`import views;`), for each group `g`:

```goose
g_count() -> i64                       g_name(i) -> const u8[:]              g_index(name) -> i64   // -1: unknown
g_meta(i) -> gweb::ViewMeta            // label, icon, fields (kind, cap, required), slots and their allow lists
g_render(out, req, ctx, name, props_json, doc, at, Z) -> bool      // false: no such view
g_defaults(name, out_json) -> bool     g_form(out, name, props_json, errs, prefix) -> bool
g_form_req(out, req, name, props_json, errs, prefix) -> bool       // the rich form, below (1.1)
g_parse(req, name, prefix, out_json, errs) -> bool                 // form to canonical JSON, then your validate
```

`Z` goes last: `views::widgets_render(out, req, ctx, "Hero", json, doc, at, fill)`. The function that passes
itself must be `recursive fn`:

```goose
recursive fn fill(out: u8[>..]&, req: const http::Request&, ctx: const gweb::Ctx&, doc: const Doc&, at: i64, name: const u8[:]) {
    // find the sections or widgets stored under (at, name) and call views::sections_render or widgets_render with fill
}
```

**JSON.** Writing is canonical: keys in declaration order, enums by variant name, defaults written. Reading is lenient:
an unknown key is ignored, a missing field takes its default, a value of the wrong type takes the default and counts
one warning, text over its cap is cut on a character boundary (and counts), and a repeater keeps at most its limit (64
for `T[>..<]`).

**Forms.** `g_form` writes one control per field (`name="PREFIX" + field`; a struct adds `name.`, a repeater item
`name.K.` and a hidden `name.n`). `g_parse` reads the same names, runs `validate`, and writes the canonical JSON.
`gweb::form_enum` is the helper for enums. A view is limited to 32 fields and 8 slots.

`validate` names fields plainly (`"title"`); `g_parse` puts the form prefix in front of each error, so the message
shows under the control (`w.title`). After an error `g_parse` still writes the JSON it read (a field that did not
parse keeps its default), so the page can draw the form again: `g_form(out, name, json, errs, prefix)`. To show the
text the user typed, use `g_form_req`.

**The rich form (1.1).** `g_form_req(out, req, name, json, errs, prefix)` draws the same controls as `g_form`, and:

- **Shows what was typed.** After a failed POST, a field that has an error shows the posted text (`12a`, or text over
  its cap), not the default that `g_parse` kept. A GET request, and a field without an error, show the stored value.
  Pass the POST request you parsed. A foreign field (`ns::T`) draws itself through `gw_field` and is not changed.
- **Links help to the control.** `<small class="gw-help" id="NAME-help">`, and the control's `aria-describedby` lists
  the help id and the error id (`NAME-help NAME-error`).
- **Repeater buttons that work without JS.** Each item ends with Up, Down and Remove, the list ends with Add, all
  submit buttons named `PREFIX + field + ".act"` with the value `up:K`, `down:K`, `del:K` or `add`. `g_parse` reads
  the items, applies the action, drops the errors of the other fields, and returns false with no errors: draw the form
  again with `g_form_req` instead of saving. At the limit, Add is disabled, and a posted Add gives "Too many items."
  A hidden first button (`value=""`) makes Enter in a text field act as Save, not as the first item's button.
- **Labels items.** `let ITEM_LABEL = "title";` names a text field of the item struct. The legend reads `#2: Eggs`.
  A name that is not a text field of the item is a build error at the line.

`g_form` and `form` keep their 1.0 markup.

The struct scanner is `cli/structs.goose`; the form decoders (Forms and validation) use it too.

## Markdown

`@gweb::markdown(props.body)` (or `gweb::markdown(out, src)`) renders a small, safe subset of Markdown, in Goose:
ATX headings, paragraphs, `*em*` and `**strong**` (and `_`), code spans, fenced code (the language becomes
`class="language-x"`), links and images, bullet and ordered lists nested by indent, block quotes, `---`, hard breaks
and backslash escapes. Lists are always tight. There are no tables, setext headings, indented code or footnotes.

- Raw HTML is escaped, never passed through, and `&` always becomes `&amp;`.
- A link or image URL must be relative, or start with `http:`, `https:` or `mailto:`. Any other URL (`javascript:`,
  `data:`, `//` with a backslash, anything with a space or control byte) leaves the whole construct as plain text.
  Absolute links get `rel="noopener"`.
- Input is cut at 64 KiB, containers nest 8 deep (deeper markers are text), a URL is at most 2,000 bytes. A 20 KB
  document renders in about 0.13 ms.
- `gweb::markdown_text(out, src, max)` writes the plain text (markup removed, white space collapsed) for excerpts and
  meta descriptions: at most `max` bytes, cut at a word with "…".

Render at read time and let the page cache absorb the cost; stored HTML goes stale when the renderer changes.

## Reserved prefixes

`gweb::reserved_prefixes() -> const u8[:][:]` is generated into `main.goose`: every literal first segment of a route,
every top-level name in `public/`, `sitemap.xml` and `robots.txt` when generated, `_gw` and `__gweb`. A content tree that
serves the root through a catch-all uses it to refuse a slug that would shadow one.

## Packages

A package is a folder with `gweb.package`, and components, routes, public
files and `lib/` code. List one in `gweb.packages`: a path, `owner/repo@tag` (GitHub), or a git URL
(`file:///path/to/repo.git@tag` or `https://host/path@tag`), with `at /prefix` to mount its routes. See [docs/site/packages.md](docs/site/packages.md).

A plain Goose library (goose-postgres, goose-blob) is declared by `package NAME SOURCE` in the same file, for example
`package pg josephheinz/goose-postgres@v0.1.0`. Files then say `import pg;`. gweb writes the line into the generated
root for the build, `gweb test`, `check`, `lsp-gen` and `export`. A package's `gweb.package` may list the ones it needs.
`GWEB_PKG_NAME` points a name at a local checkout.

A package's `views/` folder joins the project's views, like its `components/`. A package may be mounted inside
another package's mount (`../shop at /admin/shop` beside `../admin at /admin`), when the outer package has no folder
of that name.

`gweb.package` has `name IDENT` and `gweb VERSION`, the lowest gweb it needs. `gweb 1.0` accepts 1.0.0 and every later
1.x and 2.x; `1.2.3` and `1.0.0-rc1` work too. The versions are compared as numbers (0.10 is above 0.7), and a
prerelease is below its release.

A mounted package learns where it is mounted. gweb writes `NAME::MOUNT` for it, as in `cms::MOUNT == "/admin"`
(`"/admin/shop"` for a module mounted inside it), so a login guard does not hard-code `/admin/login`:

```goose
var login: u8[>..] = [];
format(login, cms::MOUNT, "/login");
return gweb::require_login(req, ctx, res, login);
```

## How it runs

- The default is min(performance cores, 4) workers; `--workers N` or
  `GWEB_WORKERS` override it. On the test Mac, more workers only helped
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
- Pages render on every request into one buffer (unless `REVALIDATE`, below); static files go out
  from the binary's data with `writev`, without a copy.
- gweb speaks plain HTTP/1.1. For TLS, HTTP/2 and compression run it behind Caddy or
  nginx: see [docs/DEPLOY-PROXY.md](docs/DEPLOY-PROXY.md).

## Operations

Full guide: [docs/DEPLOY.md](docs/DEPLOY.md). Design: [DESIGN-ADDENDUM-16-OPERATIONS.md](docs/DESIGN-ADDENDUM-16-OPERATIONS.md).

- **Health.** `/__gweb/health` (liveness) and `/__gweb/ready` (503 once a stop begins). `server --probe` exits 0 or 1 for a Docker `HEALTHCHECK`.
- **Graceful stop.** SIGTERM or SIGINT stops accepting, finishes requests for up to `--drain-ms` (10 s), runs `state::shutdown` if defined, and exits 0. `--drain-delay-ms` keeps accepting first, so a load balancer can stop routing. A second signal exits at once.
- **Restarts.** SIGUSR2 starts the new binary on the same socket and drains the old one (systemd `reload`). A systemd socket unit or a rolling update also loses no request. Migrations must keep the previous release working.
- **Logs.** stdout. `--log-format json` for JSON lines, `--log-level`, `--access-log` for the access log (with `X-Request-Id`). In code: `gweb::log_info(ctx, "msg")`, or `gweb::log_event`, `gweb::log_field`, `gweb::log_emit`.
- **Metrics.** `--metrics` serves Prometheus text at `/__gweb/metrics`; block it at the proxy. `gweb::metric_count(name, n)` and `gweb::metric_gauge(name, v)` add your own.
- **Tracing.** Set `OTEL_EXPORTER_OTLP_ENDPOINT` (plain `http://`, a local collector). W3C `traceparent` in, OTLP/HTTP JSON out; `gweb::span(ctx, "name")` adds spans.
- **Jobs.** An in-memory queue and a scheduler, in `app/jobs.goose`:

```goose
enum Job { Welcome { user: i64 }, Cleanup }

fn run(job: const Job&, ctx: gweb::Ctx&) -> bool {              // false: retried with backoff, 5 attempts
    match job {
        Welcome w => { return send_welcome(w.user); },
        Cleanup => { return true; },
    }
}

fn schedule(s: gweb::Schedules&) {                              // optional
    jobs::every(s, "cleanup", 5 * 60 * 1000, Job.Cleanup);
    jobs::cron(s, "digest", "0 8 * * 1", Job.Cleanup);         // Mondays 08:00, local time (TZ)
}
```

  `jobs::every_local(s, name, ms, job)` (1.1) is `every` that still fires under `--no-schedule`. Run many instances with
  `--no-schedule` on all but one for the shared schedules (a digest, a cleanup), and use `every_local` for the work
  each instance must do itself, such as bumping its own cache epoch. Names are shared with `every` and `cron`, and a
  duplicate is refused as before (the server exits 1).

  Enqueue from a handler with `jobs::enqueue(ctx, jobs::Job.Welcome { user: id })`. Queued jobs are lost on a restart; for durable work use an outbox table (see the guide).

## SQLite

Apps can read SQLite through the sibling package
[goose-sqlite](https://github.com/josephheinz/goose-sqlite): write `import sqlite;` in a `lib/` or `app/`
file, and `gweb` declares the package. Each worker opens its own connection: `sqlite::local(path)` for a
database nobody writes, or `sqlite::local(path, sqlite::Mode.QueryOnly)` for one the app writes. See
`../examples/shop/lib/shopdb.goose`.

**Writes.** Workers never write. The owner thread in `app/state.goose` holds the one writer, `sqlite::writer(path)`,
and a worker sends it a typed `Msg`. The owner binds, runs and commits each write as one
`sqlite::begin` / `sqlite::commit` transaction, and replies with a row or an error code. A worker that
aborts mid-transaction would keep its write lock; an abort on the owner ends the process instead.
`state::init` runs `sqlite::migrate` and exits when that fails, so the schema is ready before the first request.
The app maps `sqlite::busy` to 503, `sqlite::constraint` to 409 and a missing row to 404. Commits use
`synchronous=NORMAL`; pass `durable: true` to `writer` to survive a power loss. See
`../examples/shop/lib/todosdb.goose`.

## Cookies

Read cookies from `req`, set them through `ctx`. Setting works the same in a
route handler, a page loader and middleware, and every accepted cookie is sent
whatever the outcome (200, redirect, not found, or a `before` that returned
false). `run_worker` moves the pending `Set-Cookie` lines into `res.headers`
after the dispatcher returns.

```goose
let theme = gweb::cookie_or(req, "theme", "light");          // decoded; an owned value, for layouts and templates
let n, ok = gweb::cookie_int(req, "visits");                 // decoded, then parsed: i64, bool
var v: u8[>..] = [];
let has = gweb::cookie(req, "name", v);                      // decoded, appended to v
let raw, has_raw = gweb::cookie_raw(req, "name");            // as sent, still encoded

gweb::set_cookie(ctx, "seen", "1");                          // session cookie, HttpOnly, SameSite=Lax
gweb::set_cookie(ctx, "theme", "dark", gweb::CookieOptions { max_age: 31536000, http_only: false, .. });
gweb::clear_cookie(ctx, "theme");                            // pass the same path and domain it was set with
```

A layout can read a cookie without a loader: `<body class="{gweb::cookie_or(req, "theme", "light")}">`.

`CookieOptions` has `path` (`/`), `domain` (none, this host only), `max_age`
(-1: until the browser closes), `secure` (false), `http_only` (true) and
`same_site` (`SameSite.Lax`, `Strict` or `None`). `SameSite.None` always writes
`Secure`. `secure` defaults to false because gweb serves plain HTTP; set it
when the site is behind TLS.

`set_cookie` returns false and sets nothing when the name is not an RFC 6265
token of 1 to 64 bytes, the path or domain is bad, `max_age` is below -1, a
`__Secure-` or `__Host-` prefix rule is broken, or the encoded value is over
1024 bytes. Check the result for values that come from users: Goose does not
warn about an ignored `bool`. Every byte of the value outside `A-Z a-z 0-9 - . _ ~`
is written as `%XX`. `cookie`, `cookie_or` and `cookie_int` all decode it again; `cookie_raw`
returns the bytes as sent. `cookie_or` returns an owned `u8[>..]`, so a `Props` field that holds it
is `u8[>..]` (the last field) or `u8[..N]`, not a slice.

All `Set-Cookie` lines of one response share 2048 bytes. When they do not fit
beside the headers already in `res`, the reply becomes a bare
`500 {"error":"response headers too large"}`; a cookie is never dropped silently.
Pages that set cookies carry no `Cache-Control`; behind a shared cache, set
`Cache-Control: no-store` in `after` middleware. Signed sessions are not in v1.
The demo is `../examples/shop/app/cookies` (`/cookies`).

## CSRF

Every page `fn POST` and every `route.goose` that defines `POST`, `PUT`, `PATCH` or `DELETE`
checks a CSRF token before `before` middleware runs. The token is 32 random hex digits in an
HttpOnly cookie, `gw_csrf`, and a form sends the same value back in a hidden `_csrf` field
(a script sends it in an `X-CSRF-Token` header). It is a double-submit cookie with no server
secret, one token for the browser session.

```html
<form method="post" action="/x">@gweb::csrf_field(ctx) ... </form>
<meta name="csrf-token" content="{gweb::csrf_token(ctx)}">   <!-- a script sends it as X-CSRF-Token -->
```

- `gweb` starts the token (cookie and `Cache-Control: no-store`) for a page whose `page.html`,
  `page.goose` or wrapping `layout.html` mentions `gweb::csrf_`. A field written by a `lib/` partial is
  not seen by that scan; call `gweb::csrf_begin(req, ctx, res)` from `before` middleware, which does
  nothing when the token is already started. Pages that use no token send no cookie and no header.
- A gw-target form sends its hidden field with the fragment POST, so fragments need no extra code.
  Put the field inside the fragment so it comes back in every reply.
- When `X-CSRF-Token` is present only the header is read; otherwise the `_csrf` field of a
  urlencoded body. `_csrf` is a reserved form field name.
- A bad token gets `403` with `CSRF token missing or wrong; reload the page and try again`.
  A request whose `Sec-Fetch-Site` is anything but `same-origin` or `none` (so `cross-site` and
  `same-site`) gets `403 cross-site request refused`. Browsers send that header only over HTTPS and
  to `localhost`, so on plain HTTP the token is the check that counts.
- A route turns both checks off with `const CSRF = false;` on a line of its own, for APIs called by
  clients that are not browsers, webhooks, and cross-site browser callbacks (an OIDC `form_post`, a
  3-D Secure return). A route that opts out must not trust cookies for authority. Pages have no opt-out.
- Behind a TLS proxy that sends `X-Forwarded-Proto: https`, with `GWEB_TRUST_PROXY=1`, the cookie is `__Host-gw_csrf`
  with `Secure`, and a plain `gw_csrf` cookie is ignored. Without `GWEB_TRUST_PROXY` the header is ignored, because a client
  can send it, and the cookie is plain `gw_csrf`.
- `gweb::login` rotates the token. The token itself needs no `GWEB_SECRET`.

## Config and secrets

`gweb` loads `.env` files from the project folder at startup. The first file to set a name wins, and
the real environment beats every file:
`.env.<env>.local`, `.env.local`, `.env.<env>`, `.env`. `<env>` is `GWEB_ENV`, else `development`
under `gweb dev` and `production` otherwise. Lines are `NAME=value`; `#` starts a comment line.

```
# .env.local   (git-ignored)
GWEB_SECRET=3f1c...64 hex digits...   # openssl rand -hex 32
```

- `GWEB_SECRET` is 1 to 4 comma-separated keys of 32 to 64 bytes. The first signs, all verify, so
  you rotate by putting the new key first. Put it in `.env*.local` (git-ignored by `gweb new`) or the
  real environment, never in a committed `.env`.
- `gweb dev` makes a throwaway key in `.gweb.dev/secret` when none is set. Production refuses to
  start without `GWEB_SECRET` when the app uses sessions or signed cookies.
- Read your own settings with `gweb::env_str`, `env_int`, `env_bool` and `env_required`. An
  optional `app/config.goose` with `fn check() -> bool` runs before the server listens; false exits 2.
- `GWEB_SESSION_IDLE` and `GWEB_SESSION_MAX` are seconds (defaults 86400 and 2592000).
- **`GWEB_TRUST_PROXY=1`** makes gweb believe the proxy headers: the last `X-Forwarded-For` item for `client_ip`, and
  `X-Forwarded-Proto: https` for the `__Host-` prefix and `Secure` of the session and CSRF cookies and for `gweb::site_url`.
  **An app behind a TLS proxy must set it**, or its cookies are not `Secure`. Leave it off when clients reach the server
  directly, or they can pick their own address and scheme.

## Sessions and login

A session is a signed cookie, `gw_session`: user id, your version number, times and up to 256 bytes
of data. It is **signed, not encrypted**: the user can read it, so keep secrets out of it. It needs
`GWEB_SECRET`. Nothing reads it until you call `gweb::session`.

```goose
// app/login/submit/route.goose
fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    // ... read username and password with gweb::form ...
    if !gweb::rate_limit(req, ctx, res, "login", 10, 60) { return; }
    if !gweb::password_verify(stored_hash_or_empty, password) { /* same error for both failures */ return; }
    if !gweb::login(req, ctx, res, user.id, user.session_version) { return; }
    gweb::redirect(ctx, gweb::safe_next(next, "/"), 303);
}
```

```goose
// app/admin/middleware.goose
fn before(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) -> bool {
    if !gweb::require_login(req, ctx, res, "/login") { return false; }   // 303 to /login?next=...
    if ctx.session.ver != user_row.session_version { gweb::logout(req, ctx); gweb::redirect(ctx, "/login", 303); return false; }
    return true;
}
```

- **Revocation is yours.** Check `ctx.session.ver` against the user row and bump the row's version
  on password change, role change or "log out everywhere".
- **Logout must be POST** (a form with `@gweb::csrf_field(ctx)`); a link would let any site log users out.
- `gweb::login` makes a new session id, rotates the CSRF token and sets `no-store`. Pass
  `gweb::LoginOptions { remember: true, .. }` for a persistent cookie.
- Passwords: `gweb::password_hash` makes a `$pbkdf2-sha256$600000$...` string; `password_verify("", pw)`
  for an unknown user costs the same as a wrong password; `password_needs_rehash` tells you when to re-store.
  A login holds a worker for a fraction of a second, so rate-limit it.
- **An expired session in a fragment or boosted request** (1.1). `gwf.js` and `gwn.js` send `GW-Auth: 401`. For such a
  request `require_login` answers `401` with `GW-Login: <login URL, with next for a GET>`, instead of the 303, so the
  login page is not morphed into the page. The client fires a cancelable `gw:unauthorized` event on `window` (detail:
  the reply). If no listener calls `preventDefault()`, it navigates to the URL it requested, and the server's redirect
  takes the browser to the login. A request without the header (a browser, curl, an older runtime) gets the 303.
  `gwn.js` now fetches with the header too, so a boosted link to a guarded page behaves the same way.
- `gweb::require_login_api` answers `401` JSON. In templates: `gweb::user_id(ctx)`, `gweb::logged_in(ctx)`.
- A page's `fn POST` cannot refuse with a `429`; do the login in a `route.goose` and point the form at it.
- Behind a TLS proxy (`X-Forwarded-Proto: https` and `GWEB_TRUST_PROXY=1`) the cookie is `__Host-gw_session` with `Secure`.
- Also available: `gweb::set_signed_cookie` and `gweb::signed_cookie` (700 bytes, name under the MAC).

## Rate limits

```goose
if !gweb::rate_limit(req, ctx, res, "login", 10, 60) { return; }               // 10 a minute per client address
if !gweb::rate_limit_key(ctx, res, "login-user", username, 5, 60) { return; } // 5 a minute per user name
```

A refusal has already written `429`, `Retry-After` and the body, so you just return. The table is
process-wide, shared by all workers, and lost on restart. It is a speed bump, not a firewall: an
attacker with many addresses can evict entries. See `GWEB_TRUST_PROXY` above for `client_ip`.

## CORS

Call `gweb::cors` in a route's `middleware.goose` `before`:

```goose
fn before(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) -> bool {
    return gweb::cors(req, ctx, res, gweb::CorsOptions { origins: "https://app.example", .. });
}
```

- `origins` is a comma list of exact origins, or `*`. Preflights are answered with `204` (or `403`)
  and end the request. `credentials: true` never matches `*`.
- Pages get no CORS.
- A cross-origin `POST` also needs `const CSRF = false;` on the route, because the CSRF check refuses
  `cross-site`. Such a route must not trust cookies, unless you set `credentials: true` with a
  deliberate origin list: then a request from any other origin with an unsafe method gets `403`.

## Security headers and CSP

Every response carries `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`
and `X-Frame-Options: SAMEORIGIN`. `GWEB_SECURITY_HEADERS=0` turns them off; a handler can set
`ctx.default_headers = false`. `GWEB_HSTS=<seconds>` adds `Strict-Transport-Security`.

CSP is opt-in: `GWEB_CSP=1` (or `--csp`), or `report-only` to watch without blocking, or
`gweb::csp_begin(ctx)` in one subtree's `before`. HTML replies get
`script-src 'self' 'nonce-N'; object-src 'none'; base-uri 'self'; frame-ancestors 'self'`.

- Inline scripts need the nonce: `<script nonce="{gweb::nonce(ctx)}">`.
- Inline `on*` handlers (`onclick=...`) are blocked; use a script. `/_gw/*.js` is covered by `'self'`.
- Styles are not restricted.

## Fragments

A link or form marked `gw-target="NAME"` fetches its normal URL, and the server
answers with only the `{#fragment NAME}` region of that page, without the
layout. The runtime (`/_gw/gwf.js` on any page with a `gw-target`, which
imports `gwi.js`) morphs the reply into the element with `id="NAME"`. Without
JavaScript the same link or form does a normal navigation and gets the whole
page.

```html
<ul id="todo-list">{#fragment todo-list}
{#for t in props.todos}<li>{t.title}</li>{/for}
{/fragment}</ul>
<form method="post" action="/todos" gw-target="todo-list"> ... </form>
<a href="?cat=home" gw-target="results">home</a>
<a href="/fragments/products/{p.id}" gw-target="detail">Quick view</a>
```

- The fragment is a region of a `page.html` (not a layout, not a component). It goes right after the
  opening tag that has `id="NAME"`, on the same line, and `{/fragment}` right before that
  element's closing tag, so the reply and the DOM line up. A name is `[A-Za-z][A-Za-z0-9_-]*`,
  at most 64 bytes; a page has at most 8 fragments, none inside `{#if}`, `{#for}` or another fragment,
  and no `@Component()` inside.
- A fragment sees `props`, `req` and `ctx`. A top-level `{#let}` ends at the next fragment tag.
- The tags emit no bytes: a page is the same with or without them.
- The request is the page's URL plus the header `GW-Fragment: NAME`. The reply is the region, with
  `GW-Fragment: NAME` echoed and `Cache-Control: no-store`. An unknown name gives the whole page.
- `gw-target` goes on `<a href>` or `<form>` (`method` get or post). `gweb` checks it at build time:
  the URL (`/path`, `?query` or empty for the page itself; a `{expr}` segment matches a `[name]`
  folder) must reach a page that has `{#fragment NAME}`, and `method="post"` needs `fn POST(` in that page.
- A `page.goose` may define `fn POST(req, ctx) -> Props`, which runs in place of `load` for POST
  (it needs `load` beside it). Return `load`'s props with what the form changed. A POST without the
  header renders the whole page with status 200; for post-redirect-get call `gweb::redirect(ctx, "/x", 303)`.
  A POST must carry the CSRF token (see CSRF); other methods get 405.
- The morph matches keyed elements by `gw-key` and other nodes by position. Give `gw-key`, unique
  among its siblings, to every item of a list that can be reordered or lose an item other than the
  last (`<li gw-key="{t.id}">`), and to an element that comes and goes in front of other siblings.
  An unkeyed element that comes and goes must be the last child of its parent. This rule applies to
  components too.
- `import gweb.forms.form;` gives `gweb::form(req, "name", out)` (URL-decoded, appended to `out`) and
  `gweb::form_int(req, "id")`. Several intents on one page are told apart by button names:
  `<button name="remove" value="3">`.
- Not supported: append/prepend swaps, a target inside a component.
- The runtime sets `aria-busy="true"` on the target while a request runs, and a failure raises `gw:error`
  (the dev overlay shows it as a `page error`). The last request per target wins.

## Forms and validation

A struct named `*Form` in `page.goose` or `route.goose` is a form schema. `gweb` generates
`decode(req, ctx, form, errs) -> bool` for it. Field types are the rules: `u8[..N]` text of at most N
bytes, `i64` a whole number, `bool` a checkbox, `gweb::Upload` a file (below). A field with no default
is required. Other types are a build error; write your own `fn decode` and `gweb` stops you.
Text is kept as typed, not trimmed.

```goose
import gweb.forms.form;
struct SignupForm { email: u8[..200], age: i64, newsletter: bool, note: u8[..500] = "" }
struct Props { form: SignupForm, errs: gweb::FieldErrors }

fn POST(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    var p = load(req, ctx);
    if !decode(req, ctx, p.form, p.errs) || !gweb::check_email(p.errs, "email", p.form.email) {
        gweb::unprocessable(ctx);         // status 422
        return p;
    }
    gweb::redirect(ctx, "/thanks", 303);
    return p;
}
```

```html
<p><input name="email" value="{gweb::field_value(req, "email", "")}"@gweb::invalid(props.errs, "email")>
@gweb::field_error(props.errs, "email")</p>
```

- Other checks: `gweb::check_length`, `check_range`, `check_one_of`, `add_error(errs, field, msg)`. The first
  error per field is kept. A route answers with `gweb::errors_json(res, errs)` (422).
- `FieldErrors` holds 64 errors. When a form would go past that, the last slot becomes a form-level error
  (`gweb::error_for(errs, "")`, "Too many errors to show here") and `errs.dropped` is true, so the editor is told that
  some are missing.
- Two helpers once shared a name: `gweb::form_int(req, "id")` reads one field as `i64, bool`, and `gweb::form_i64(req,
  field, out, errs, required)` is what a `*Form` decoder calls for an `i64` field. `form_text`, `form_bool`, `form_enum`
  and `form_upload` are the other decoders; they all live in `gweb.forms.valid`.
- `field_value` shows what was posted, so a bad number comes back as typed.
- A 422 reply to a `gw-target` form is morphed in like a 200; without JavaScript it is a normal page.
  Keep the error `<span>` last in its parent (see the morph rule under Fragments).
- Templates get `gweb::valid` by default. `page.goose` imports `gweb.forms.form` and `gweb.forms.valid` itself;
  `gweb` adds `import gweb.forms.valid;` and `import gweb.forms.upload;` to a file with a `*Form` struct.
- Structs in `lib/` get no decoder.

## File uploads

A `multipart/form-data` post works with the same `*Form` and `fn POST` code. A `gweb::Upload` field is a file;
text fields reach `gweb::form` and the CSRF check as usual (put `@gweb::csrf_field(ctx)` in the form).

```html
<form method="post" enctype="multipart/form-data">@gweb::csrf_field(ctx) <input type="file" name="photo"> ...</form>
```

```goose
import gweb.forms.upload;
const MAX_UPLOAD = 2000000;                      // optional, per page or route: 413 above it
struct UploadForm { photo: gweb::Upload }

...  if !decode(req, ctx, p.form, p.errs) || !gweb::check_upload(p.errs, "photo", p.form.photo, 2000000, ["image/png", "image/jpeg"]) { ... }
var name: u8[>..] = [];  gweb::safe_name(name, p.form.photo.filename);
gweb::save_upload(p.form.photo, dest);            // false if dest exists; the file moves
```

- `--max-upload N` (`GWEB_MAX_UPLOAD`, default 32 MiB) caps a multipart body; `--max-body` still caps everything else.
  A multipart body over 64 KiB is spooled to a file in `--upload-dir D` (default `.gweb.uploads`) as it arrives.
  One server per upload dir: files left by an earlier run are deleted at start.
- Limits: 8 files (`--max-upload-files`, up to 16), 64 parts (`--max-upload-parts`), 64 KiB per text field
  (`--max-upload-text`); each has a `GWEB_*` variable. A malformed body is a 400, a file over the limit a 413.
- Unsaved files are deleted after the response. Use `gweb::save_upload` to keep one.
- `filename` and `content_type` are what the client said. `check_upload` checks the sniffed type (PNG, JPEG,
  GIF, WebP, PDF; never SVG). Build the saved name with `gweb::safe_name`.
- A `gw-target` form with `enctype="multipart/form-data"` is sent as `FormData`.

## Error pages

`error.html` in an app folder is the error page for the pages and routes at or below it; the nearest wins.
It renders inside the layouts above its own folder and sees `err: gweb::ErrorInfo`
(`status`, `message`, `id`, `crashed`, `detail`).

```html
<h1>{err.status}</h1><p>{err.message}</p><p>Error id: {err.id}</p>
```

```goose
import gweb.site.errors;                       // page.goose needs this for gweb::fail
fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    if !allowed(ctx) { gweb::fail(ctx, 403, "Not yours."); return Props { .. }; }
    ...
}
```

- `gweb::fail(ctx, status, message)` ends the reply with the error page; a route gets `{"error":..,"id":..}`.
  `gweb::not_found` still uses `not-found.html`.
- A crash (bounds error, failed `guard`, any abort) is answered by the supervisor with the error page
  (`crashed` is true) and `Connection: close`. If that fails too, a fixed plain-text 500. The crashed
  worker's other keep-alive connections are closed; clients reconnect.
- Without `error.html`: a small built-in page. The id is in the log line.
- In `gweb dev` the page also carries the abort text and the source lines around each location, in the
  overlay. Production never shows them. Build errors in the overlay get source lines too.
- `gweb::done(ctx)` lets a page `fn POST` or `fn load` that took `res` write the whole reply itself
  (a `Retry-After`, a JSON body); no template renders.

## Loading states

`loading.html` in an app folder is a template with no props. Whole-page renders of pages at or below it carry it
as `<template id="gw-loading">`. After 150 ms without a reply, `gwi.js` fills a link's `gw-target` box with it;
the reply morphs over it, and a failure restores the old content.

```html
<a href="/products" gw-target="results">Products</a>
<form method="post" gw-target="list" gw-loading>...</form>     <!-- a form opts in; gw-loading="id" picks another template -->
```

`gw-loading="none"` turns it off for a link. No fragments or `@slot()` in `loading.html`. It does not show on first
page load (that needs streaming).

The demo is `../examples/shop/app/fragments` (`/fragments`, `/fragments/products`).

## Assets and caching

Every file in `public/` is served at its plain URL and at a hashed one: `/css/site.css` and
`/css/site.3f9a1c2b.css` (the first 8 hex digits of its ETag). The hashed URL sends
`Cache-Control: public, max-age=31536000, immutable`; the plain URL sends `max-age=0, must-revalidate`
and answers 304. `/_gw/` runtime modules keep plain URLs and revalidate.

```html
<link rel="stylesheet" href="@asset("/css/site.css")">      <!-- /css/site.3f9a1c2b.css -->
```

- `@asset("/path")` takes one string literal and fails the build when `public/path` does not exist.
  For a path known at run time, `gweb::asset_url(path)` returns the hashed URL, or `path` when unknown.
- Text files of 1 KB or more are gzipped at build time (`Content-Encoding: gzip`, `Vary: Accept-Encoding`,
  ETag ending `-gz`) when the client sends `Accept-Encoding: gzip`. HTML and JSON are not compressed here;
  the proxy does that.
- CSS is minified in `build`, `start` and `export` (not `dev`; `--no-minify` turns it off). Comments go
  except `/*! ... */`; strings and `url(...)` stay as written.
- A hashed URL that equals another static or route URL is a build error.
- URLs inside CSS (`url(/img/x.png)`) are not rewritten; they use the plain URL and revalidate with 304.

## Images and metadata

```html
@image("/img/hero.png", props.alt)
@image("/img/hero.png", "", "class=\"wide\" loading=\"eager\"")
```

`@image(path, alt[, attrs])` writes `<img src width height alt loading="lazy" decoding="async">`. The size
is read from the file at build time (PNG, GIF, JPEG, WebP, SVG; no `width`/`height` when unreadable). A file
`hero@2x.png` beside `hero.png` adds `srcset="... 1x, ... 2x"`. `alt` is any expression and is escaped;
`attrs` is a string literal copied as written, and `loading` or `decoding` in it replace the defaults.
There is no resizing; make the variants yourself.

At run time, `import gweb.site.image;` gives `gweb::image_size(data) -> w, h, known` for the bytes of an image
(the reader `@image()` uses at build time) and `gweb::image_size_file(path) -> w, h, known`. A size is `known`
when the header is complete and the width and height are above 0; an SVG in percent or `em` has none. Use it
for an upload's size, as `check_upload` has checked its type.

```goose
fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    ctx.title = "Pricing";
    gweb::meta_description(ctx, "Plans and prices.");
    gweb::meta_canonical(ctx, "/pricing");     // "/..." becomes absolute with SITE_URL
    gweb::meta_image(ctx, "/img/og.png");
    gweb::meta_robots(ctx, "noindex");
    ...
}
```

Put `@meta()` once in `layout.html`'s `<head>` (it is an error elsewhere). It writes only the tags that are
set: `description`, `canonical`, `robots`, `og:title` (from `ctx.title`), `og:description`, `og:url`,
`og:image` and `twitter:card`. It does not write `<title>`. Setters cut at 320, 512, 512 and 64 bytes.
`import gweb.site.meta;` for the setters.

Set `SITE_URL=https://example.com` in production. Without it, absolute URLs use the `Host` header, which
the client controls. `gweb::site_url(req, out)` appends the base.

## Sitemap and robots.txt

An `app/sitemap.goose` (even an empty one) turns on `GET /sitemap.xml` and, unless `public/robots.txt`
exists, `/robots.txt` (`Allow: /` and the sitemap line). Both send `Cache-Control: public, max-age=3600`.

```goose
import std;
import net.http;
import gweb;
import gweb.site.sitemap;

fn entries(req: const http::Request&, ctx: gweb::Ctx&, s: gweb::Sitemap&) {
    gweb::sitemap_add(s, "/blog/hello", "2026-11-12");    // path starts with /, lastmod is YYYY-MM-DD or ""
}
```

The sitemap lists every page with no dynamic segment, then the entries. Leave a page out with
`const SITEMAP = false;` in its `page.goose`. `sitemap_add` returns false for a bad path or date,
and past 50,000 URLs. `public/sitemap.xml` beside `app/sitemap.goose` is a build error.

`gweb::sitemap_base(s, "https://example.com")` replaces the base URL of every entry, at any time, for a site that
serves several hosts. An `fn robots(req: const http::Request&, ctx: gweb::Ctx&, out: u8[>..]&)` in
`app/sitemap.goose` writes the whole `/robots.txt` body in place of the generated one (the headers are set
for it); `public/robots.txt` still wins over both.

## Page cache and `gweb export`

```goose
const REVALIDATE = 60;     // page.goose: cache this page's GET reply for 60 s
```

- The cache is per worker (up to `workers` renders per expiry), keyed by path and query, and holds a 200
  reply of at most 1 MB. It answers with an `ETag` and `Cache-Control: public, max-age=0, must-revalidate`,
  and 304 to `If-None-Match`. Middleware `before` still runs on every request.
- Never cache a page that reads cookies or the user: every visitor would get the same HTML. A reply that sets
  a cookie is not stored, and a page that starts a CSRF token with `REVALIDATE` is a build error.
- POST and fragment requests skip the cache. Each worker keeps at most 512 entries and 16 MB.

Your own keys and the epoch, for a site that serves several hosts or changes its content at run time:

```goose
let key = str(host, "\n", req.target);                 // at most 1,280 bytes
if gweb::cache_serve_key(req, ctx, res, key) { return; }
// ... render ...
gweb::cache_store_key(req, ctx, res, key, 0);           // 0 s: keep it until the epoch changes
```

`gweb::epoch_bump()` clears every worker's cache, `REVALIDATE` pages included: each worker drops its entries the next
time it looks in its cache. Call it after a content change, from any thread. `cache_store_key` never stores a reply
that has a CSRF token, sets a cookie, or is not a plain 200.

`gweb export [-o DIR]` builds, renders the site in process and writes it to `DIR` (default `out/`):
`/` as `index.html`, `/about` as `about.html`, every static file at both URLs, and `sitemap.xml` and
`robots.txt` when enabled. Run it with `SITE_URL` set.

```goose
fn static_paths() -> u8[..1024][>..] {        // page.goose of a dynamic page
    var paths: u8[..1024][>..] = [];
    paths.push("/post/1");
    return paths;
}
```

A dynamic page without `static_paths` is skipped and listed. A non-200 page is an error and the exit
code is 1. Forms, fragments, routes and component handlers that call routes need a server.

## Streaming

A handler can send a body in chunks instead of one buffer:

```goose
import gweb.http.stream;

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    res.content_type.clear();
    res.content_type.append("text/csv");
    var s = gweb::stream_begin(req, ctx, res);   // sends the head, cookies included
    for row in rows { gweb::stream_write(s, row); }     // false when the client went away
    gweb::stream_end(ctx, s);                           // without it the connection closes
}
```

HTTP/1.0 clients get the body without chunking. A stream holds its worker until it ends: use it for
exports and downloads, and use `subscribe` (below) for anything that waits on events. `res.body` is
ignored.

## Serving files from disk

`gweb::send_file` answers a request with a file under a root folder: media a user uploaded, a download, a generated
report. `public/` is for files known at build time; this is for files that appear at run time.

```goose
import gweb.http.files;

// app/media/[key]/[name]/route.goose, serving data/media/KEY/NAME
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    var rel: u8[>..] = [];
    format(rel, gweb::param(ctx, "key"), "/", gweb::param(ctx, "name"));
    var opts = gweb::FileOptions { .. };
    opts.immutable = true;                      // the key changes when the file does
    gweb::send_file(req, ctx, res, "data/media", rel, opts);
}
```

`send_file(req, ctx, res, root, rel, opts) -> bool` is true when it sent the file or a 304. It is false after it set
a plain 404.

- `rel` is a decoded relative path. It is refused (404) when it is empty, starts or ends with `/`, has an empty
  segment, a segment that starts with `.` (so `..`, `.` and dotfiles), a `\`, a control byte, or is over 1,024 bytes.
  `%2e%2e` arrives decoded, so it is refused too.
- The real path of the file must be inside the real path of `root`. A symlink that leaves the root is a 404, one that
  stays inside is followed. Only regular files are sent.
- `Content-Type` comes from the extension (`gweb::mime_type(name)`); `opts.content_type` overrides it.
  `X-Content-Type-Options: nosniff` comes from the default headers. HTML and SVG also get
  `Content-Security-Policy: sandbox`, so an uploaded page cannot run scripts on your origin.
  `opts.sandbox = true` adds it for any type (1.1), such as a PDF, which a browser's viewer may script, whether the
  file is read whole or streamed.
- `ETag` is `"SIZE-MTIME"`, so a 304 reads no bytes. `If-None-Match` takes one tag, a list or `*`. `Last-Modified` is
  sent too, and `If-Modified-Since` (an HTTP date) gets a 304 when the file is not newer, but only when the request has
  no `If-None-Match`; a date in another format is ignored.
- `Cache-Control` is `public, max-age=0, must-revalidate`, or with `opts.immutable` one year and `immutable`.
- `opts.download` adds `Content-Disposition: attachment`; `opts.filename` sets the name shown (it also adds
  `inline; filename=` on its own). Non-ASCII names get an ASCII fallback and `filename*`.
- A file of `opts.stream_over` bytes or less (1 MiB) is read into the reply with a `Content-Length`. A bigger one is
  sent in 256 KiB windows through the stream helpers, so it never sits in memory whole. Under `gweb test` there is no
  connection, so every file is read whole.
- HEAD sends the head of a GET, with the `Content-Length` the body would have. A HEAD for a streamed file reads nothing.
- There are no range requests and no compression.

## Server push and WebSockets

One hub thread (from goose-net's `net::Hub`) owns every long-lived connection, so idle clients cost no
worker. gweb starts it when any file under `app/` or `lib/` mentions `gweb::subscribe(` or
`gweb::websocket(`, or `app/socket.goose` exists. A connection has one topic (at most 64 bytes);
`publish` reaches every connection on a topic. Needs `import gweb.http.push;`.

Server-sent events:

```goose
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    res.content_type.clear();
    res.content_type.append("text/event-stream");
    gweb::subscribe(req, ctx, res, "news", ": ping\n\n");   // heartbeat chunk every 30 s
}
// anywhere, on any thread's ctx:
gweb::publish(ctx, "news", "data: hello\n\n");
```

WebSockets:

```goose
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    gweb::websocket(req, ctx, res, "chat");                 // or (..., "chat", "https://other.example")
}
```

```goose
// app/socket.goose: all three optional; messages are dropped without fn message
fn open(ctx: gweb::Ctx&, id: u64, topic: const u8[:]) { }
fn message(ctx: gweb::Ctx&, id: u64, topic: const u8[:], data: const u8[:], binary: bool) {
    gweb::publish(ctx, topic, data, binary);                // or gweb::socket_send(ctx, id, data)
}
fn close(ctx: gweb::Ctx&, id: u64, topic: const u8[:]) { }
```

- `subscribe` and `websocket` return false after writing a reply: 503 without a hub, 400 for a bad
  request, 426 for a wrong WebSocket version, 403 for another origin.
- A browser's `Origin` must match `Host`, or the optional `allow_origin`. This stops other sites
  from using a visitor's cookies. A reverse proxy must keep `Host`.
- Other helpers: `gweb::socket_send(ctx, id, data)`, `gweb::close_socket(ctx, id)`, `gweb::subscribers(ctx, topic)`.
  The handlers in `socket.goose` can call `state::ask`.
- Limits: 10,000 connections, 64 KB per WebSocket message, 1 MB queued per slow client (then closed).
  No `permessage-deflate`.
- Authenticate in the route before calling `websocket` or `subscribe`; cookies and `ctx` work as in any
  route. A route is not CSRF-checked for GET.
- Behind a proxy: see [docs/DEPLOY-PROXY.md](docs/DEPLOY-PROXY.md).

## Route tests

`tests/*.goose` holds route tests. `gweb test` builds them with the app's real
dispatcher into one program and runs every `fn test_*(t: gweb::Tester&)` on `main`,
after `state::init()`. Requests take the worker's code path, minus the socket.

| File | Meaning |
|---|---|
| `tests/<name>.goose` | `<name>` is `[a-z][a-z0-9_]*`; write no `namespace`. Errors point at `tests/<name>.goose:LINE` |

```goose
// tests/todos.goose
import std;
import net.http;
import gweb;
import gweb.testing;

fn test_list(t: gweb::Tester&) {
    let res = site::get(t, "/api/todos");
    gweb::expect_status(t, res, 200);
    gweb::expect_contains(t, res.body, "\"title\"");
}

fn test_add(t: gweb::Tester&) {
    site::get(t, "/fragments");                                   // sets the CSRF cookie
    let res = site::post_form(t, "/fragments", "add=1&title=milk");
    gweb::expect_status(t, res, 200);
    gweb::expect_contains(t, site::get(t, "/fragments").body, "milk");
}
```

- `site::get`, `head`, `delete(t, target)`; `post_form`, `post_json`, `put_json`, `patch_json(t, target, body)`;
  `site::request(t, method, target, body, content_type)`. Each returns an `http::Response`.
- `gweb::expect(t, ok, what)`, `expect_status`, `expect_contains(t, text, needle)`, `expect_header(t, res, name, value)`, which take the response as `const&`, so bind it first (`let res = site::get(...)`);
  `gweb::header_of(res, name)` and `gweb::form_field(out, name, value)` help build and read messages.
- The jar `t.cookies` keeps `Set-Cookie` values and sends them on the next request. With `t.auto_csrf` (the default) a
  non-GET request sends the jar's `gw_csrf` as `X-CSRF-Token`, adding a fixed token when there is none. Set
  `t.auto_csrf = false` to test a refusal. `t.headers` holds extra header lines for the next request only.
  `t.host` is the `Host` header of every request (`test`): set it to test an app that serves several hosts.
- `state::ask` calls `state::handle` directly on `main`.

Rules for authors:
- Tests run in file order, then in source order. They share `state`, the database and the jar unless a test
  resets `t.cookies`.
- Point the app's database at a test file through its environment variable.
- A test that aborts ends the run; the `== <test>` line before it names the test.
- Tests are not part of the server: `gweb build` ignores `tests/`.

## i18n

`locales/default` holds the default locale's tag (`en`). `locales/<tag>.txt` holds one catalog per locale; `<tag>` is
like `en`, `de` or `pt-BR`. `gweb` compiles them to `.gweb/t.goose`, and pages and layouts can call `t::` (a route, middleware or `lib/` file writes `import t;`).

```
# locales/en.txt
greeting = Hello, {name}!
cart_items[one] = {count} item in your cart
cart_items[other] = {count} items in your cart
stock = Only {n:int} left
```

- One `key = text` per line; `#` starts a comment line. A key is `[a-z][a-z0-9_]*`, not a Goose keyword, and not
  `tag`, `find` or `TAGS`. Escapes: `\n`, `\{`, `\}`, `\\`.
- `{name}` is a text argument and `{name:int}` an `i64`. Write the type in the default locale, on the argument's first
  use; other locales write `{name}` and may leave an argument out, but not add one.
- `key[one]`, `key[other]` and so on (`zero one two few many other`) are plural forms. The default must give
  `[other]`. The selector is the `i64` argument `count`, which comes first.
- A key a locale lacks uses the default's text; a missing plural form uses that locale's `[other]`, then the
  default's. The build prints `gweb: locales/de.txt lacks 1 key (falls back to en): a`. Bad syntax, duplicates, keys or
  arguments the default lacks, type clashes, a bad tag, a plural without `[other]` and a missing `locales/default`
  are build errors at `locales/<file>:LINE`.

Generated, per key, a pair of functions (`t::greeting(ctx, name)`, and `t::greeting(loc, name)` for code without a `Ctx`),
plus `t::TAGS`, `t::tag(ctx)` and `t::find(tag)` (case-insensitive, `-> i64, bool`):

```html
<html lang="{t::tag(ctx)}">
<p>{t::cart_items(ctx, p.n)}</p>
```

`{expr}` escapes, so messages are plain text.

The locale is `ctx.locale`, set before routing: the `locale` cookie (exact tag), then `Accept-Language` by q-value
(`de-AT` takes `de`, `en` takes `en-GB`), then the default. With two or more locales, responses carry
`Vary: Accept-Language, Cookie`.

For `/de/products`, use an `app/[lang]/` folder with a middleware that picks the locale:

```goose
// app/[lang]/middleware.goose
import std;
import net.http;
import gweb;
import t;

fn before(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) -> bool {
    let i, ok = t::find(gweb::param(ctx, "lang"));
    if ok { ctx.locale = i; } else { gweb::not_found(ctx); return false; }
    return true;
}
```

Not in v1: translations inside `.gshtml` components (pass translated text in as data), number, date and currency
formatting, HTML inside messages, and decimal plural operands.


## Limits

What you can change, and what is fixed. A fixed limit is part of the 1.x contract: it may grow, never shrink.

| Limit | Value | Change it with |
|---|---|---|
| Request size | 1 MiB | `--max-body`, `GWEB_MAX_BODY` |
| Multipart body | 32 MiB | `--max-upload`, `GWEB_MAX_UPLOAD` |
| Multipart parts, files, one text field | 64, 8, 64 KiB | `--max-upload-parts`, `--max-upload-files` (at most 16), `--max-upload-text` |
| Idle connection | 5 s | `--idle-ms`, `GWEB_IDLE_MS` (0: never) |
| Drain after SIGTERM | 10 s | `--drain-ms` |
| Job queue, attempts | 10000, 5 | `--job-queue`, `--job-attempts` |
| Markdown input | 64 KiB | the third argument of `gweb::markdown(out, src, max_input)` |
| Route parameters | 8, a name of 32 bytes, a value of 256 | fixed |
| Catch-all tail | 1,024 bytes | fixed |
| Route depth | 16 folders | fixed |
| Fragments per page, a fragment name | 8, 64 bytes | fixed |
| Component names (`@prop`, `@state`, `@computed`) | 31 | fixed |
| Fields of a view, slots, a repeater | 32, 8, 64 items | fixed |
| `FieldErrors` | 64 (the last is the form-level overflow error), a field of 64 bytes, a message of 200 | fixed |
| Cookie name, value, all `Set-Cookie` lines of a reply | 64, 1,024 encoded, 2,048 bytes | fixed |
| Session data, a signed cookie | 256, 700 bytes | fixed |
| A password | 1,024 bytes | fixed |
| `ctx.title`, a redirect URL | 256, 1,024 bytes | fixed |
| Meta description, canonical, image, robots | 320, 512, 512, 64 bytes | fixed |
| Page cache | a reply of 1 MiB, a key of 1,280 bytes, 512 entries and 16 MB per worker | fixed |
| Sitemap | 50,000 URLs, 2,048 bytes a path | fixed |
| Topic of a stream or socket | 64 bytes | fixed |
| A log line | 2,048 bytes; a longer one is cut and marked `truncated` | fixed |
| Metric names | 256 | fixed |
| Secret keys | 1 to 4, of 32 to 64 bytes | fixed |

## Example

`../examples/shop` is the benchmark site: pages, a JSON API, a todo list in
owner state, static files, and SQLite twins of the product routes under `/db`. Its Next.js twin is in
`../goose-bench/next-shop`.
