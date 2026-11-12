# goose-web

A Next.js-like web framework for [Goose](https://aardappel.github.io/goose/), on
[goose-net](https://github.com/josephheinz/goose-net). Folders under `app/` are routes. `gweb` turns the
project into one native binary that serves on every core.

## Install

```
git clone --branch v0.2.1 --depth 1 https://github.com/josephheinz/goose-web
cd goose-web && goose build -o gweb cli/gweb.goose
ln -s "$PWD/gweb" ~/bin/gweb           # or: cp gweb ~/bin/
```

```
gweb new mysite && cd mysite
GOOSE=/path/to/goose gweb dev          # http://localhost:60053, rebuilds and restarts on every change
```

A linked `gweb` uses its checkout as the `web` package, and a `goose-net` or
`goose-sqlite` checkout beside it. A copied `gweb` declares the tagged
releases from GitHub, and the compiler fetches them on the first build.
`gweb version` prints the version and the three sources it declares.
Set `GWEB_WEB`, `GWEB_NET` or `GWEB_SQLITE` to a path or a git source with
`@ref` to override one.

To run this package's tests from a clone, clone goose-net beside it
(`../goose-net`).

## Use the libraries without gweb

```goose
import web from "josephheinz/goose-web@v0.2.1";
import net from "josephheinz/goose-net@v0.2.1";           // goose-web needs this line too
import sqlite from "josephheinz/goose-sqlite@v0.2.1";     // only if you use SQLite
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
| `app/state.goose` | State owned by the main thread: `Msg`, `Reply`, `fn handle`, optional `fn init` |
| `lib/**.goose` | Your modules: `import lib.catalog;` (write their `namespace`) |
| `public/**` | Static files, embedded in the binary, with ETags |
| `tests/*.goose` | Route tests run by `gweb test` (see Route tests) |
| `locales/default`, `locales/<tag>.txt` | Message catalogs, compiled to the `t::` module (see i18n) |

A folder named `[id]` is a dynamic segment; `[...slug]` and `[[...slug]]` are
catch-alls (see below). Folders starting with `_` are ignored. App files get their
namespace from `gweb`; do not write one.

## Signatures

```goose
fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&)        // route.goose
fn load(req: const http::Request&, ctx: web::Ctx&) -> Props                      // page.goose
fn POST(req: const http::Request&, ctx: web::Ctx&) -> Props                      // page.goose, optional (fragments)
fn before(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) -> bool   // false: res is final
fn after(req: const http::Request&, ctx: web::Ctx&, res: http::Response&)
fn handle(msg: const Msg&) -> Reply                                               // state.goose
```

Helpers: `web::param(ctx, "id")`, `web::param_int`, `web::query(req, "q", out)`,
`web::html(res, status)`, `web::json(res, status)`, `web::not_found(ctx)`,
`web::redirect(ctx, "/to", 302)`, and `state::ask(ctx, state::Msg.List) -> Reply, bool`.
Set `ctx.title` in `load`; layouts read it.

## Catch-all routes

| Folder | Matches | Example under `app/docs/` |
|---|---|---|
| `[...name]` | 1 or more trailing segments | `/docs/a` and `/docs/a/b`, not `/docs` |
| `[[...name]]` | 0 or more trailing segments | `/docs`, `/docs/a` and `/docs/a/b` |

`web::param(ctx, "name")` returns the tail as it appeared in the path, joined with `/`
and not decoded: `a/b%20c/d`. It is `""` when an optional catch-all matched no segment.
`web::path_decode(out, tail)` appends the decoded text to a `u8[>..]` and returns false
for anything the router already refuses, so it cannot fail on a matched tail. Split the
tail with `split(web::param(ctx, "name"), '/')`.

```goose
fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    var path: u8[>..] = [];
    web::path_decode(path, web::param(ctx, "path"));
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

## Commands

```
gweb [-C dir] new <dir>      a starter project
gweb gen                     write .gooseweb/ only
gweb build [--debug]         gen, then goose build to .gooseweb/server
gweb start [flags]           build and run (--port N --workers N --log --idle-ms N --max-body N)
gweb dev [flags]             build, run with --log on 2 workers and port 60053 (unless --port), rebuild on change
gweb routes                  the route table (GET,POST and a frag line for each fragment)
gweb test                    component parity (test_* as Goose and JavaScript), then tests/*.goose route tests (writes .gooseweb.test/; leaves .gooseweb/ alone)
gweb version                 the gweb version and the package sources it declares
```

`gweb` finds the compiler in `$GOOSE`, else `goose` on `PATH`, and finds this
package beside its own binary (or `$GOOSE_WEB_HOME`). A checkout older than
the binary, or newer, stops with "rebuild gweb". Build `gweb` with:

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
let theme = web::cookie_or(req, "theme", "light");          // one raw value, for layouts and templates
let n, ok = web::cookie_int(req, "visits");                 // i64, bool
var v: u8[>..] = [];
let has = web::cookie(req, "name", v);                      // percent-decoded, appended to v

web::set_cookie(ctx, "seen", "1");                          // session cookie, HttpOnly, SameSite=Lax
web::set_cookie(ctx, "theme", "dark", web::CookieOptions { max_age: 31536000, http_only: false, .. });
web::clear_cookie(ctx, "theme");                            // pass the same path and domain it was set with
```

A layout can read a cookie without a loader: `<body class="{web::cookie_or(req, "theme", "light")}">`.

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
The demo is `../examples/shop/app/cookies` (`/cookies`).

## CSRF

Every page `fn POST` and every `route.goose` that defines `POST`, `PUT`, `PATCH` or `DELETE`
checks a CSRF token before `before` middleware runs. The token is 32 random hex digits in an
HttpOnly cookie, `gw_csrf`, and a form sends the same value back in a hidden `_csrf` field
(a script sends it in an `X-CSRF-Token` header). It is a double-submit cookie with no server
secret, one token for the browser session.

```html
<form method="post" action="/x">@web::csrf_field(ctx) ... </form>
<meta name="csrf-token" content="{web::csrf_token(ctx)}">   <!-- a script sends it as X-CSRF-Token -->
```

- `gweb` starts the token (cookie and `Cache-Control: no-store`) for a page whose `page.html`,
  `page.goose` or wrapping `layout.html` mentions `web::csrf_`. A field written by a `lib/` partial is
  not seen by that scan; call `web::csrf_begin(req, ctx, res)` from `before` middleware, which does
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
- Behind a proxy that sends `X-Forwarded-Proto: https` the cookie is `__Host-gw_csrf` with `Secure`,
  and a plain `gw_csrf` cookie is ignored.
- The token does not rotate at login, and it needs no `WEB_SECRET`.

## Fragments

A link or form marked `gw-target="NAME"` fetches its normal URL, and the server
answers with only the `{#fragment NAME}` region of that page, without the
layout. The runtime (`/_gw/gwi.js`, added by `gweb` to any page with a
`gw-target`) morphs the reply into the element with `id="NAME"`. Without
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
  header renders the whole page with status 200; for post-redirect-get call `web::redirect(ctx, "/x", 303)`.
  A POST must carry the CSRF token (see CSRF); other methods get 405.
- The morph matches keyed elements by `gw-key` and other nodes by position. Give `gw-key`, unique
  among its siblings, to every item of a list that can be reordered or lose an item other than the
  last (`<li gw-key="{t.id}">`), and to an element that comes and goes in front of other siblings.
  An unkeyed element that comes and goes must be the last child of its parent. This rule applies to
  components too.
- `import web.form;` gives `web::form(req, "name", out)` (URL-decoded, appended to `out`) and
  `web::form_int(req, "id")`. Several intents on one page are told apart by button names:
  `<button name="remove" value="3">`.
- Not supported: file uploads, append/prepend swaps, a target inside a component.
- The runtime sets `aria-busy="true"` on the target while a request runs, and a failure raises `gw:error`
  (the dev overlay shows it as a `page error`). The last request per target wins.

The demo is `../examples/shop/app/fragments` (`/fragments`, `/fragments/products`).

## Route tests

`tests/*.goose` holds route tests. `gweb test` builds them with the app's real
dispatcher into one program and runs every `fn test_*(t: web::Tester&)` on `main`,
after `state::init()`. Requests take the worker's code path, minus the socket.

| File | Meaning |
|---|---|
| `tests/<name>.goose` | `<name>` is `[a-z][a-z0-9_]*`; write no `namespace`. Errors point at `tests/<name>.goose:LINE` |

```goose
// tests/todos.goose
import std;
import net.http;
import web;
import web.testing;

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

- `site::get`, `head`, `delete(t, target)`; `post_form`, `post_json`, `put_json`, `patch_json(t, target, body)`;
  `site::request(t, method, target, body, content_type)`. Each returns an `http::Response`.
- `web::expect(t, ok, what)`, `expect_status`, `expect_contains(t, text, needle)`, `expect_header(t, res, name, value)`, which take the response as `const&`, so bind it first (`let res = site::get(...)`);
  `web::header_of(res, name)` and `web::form_field(out, name, value)` help build and read messages.
- The jar `t.cookies` keeps `Set-Cookie` values and sends them on the next request. With `t.auto_csrf` (the default) a
  non-GET request sends the jar's `gw_csrf` as `X-CSRF-Token`, adding a fixed token when there is none. Set
  `t.auto_csrf = false` to test a refusal. `t.headers` holds extra header lines for the next request only.
- `state::ask` calls `state::handle` directly on `main`.

Rules for authors:
- Tests run in file order, then in source order. They share `state`, the database and the jar unless a test
  resets `t.cookies`.
- Point the app's database at a test file through its environment variable.
- A test that aborts ends the run; the `== <test>` line before it names the test.
- Tests are not part of the server: `gweb build` ignores `tests/`.

## i18n

`locales/default` holds the default locale's tag (`en`). `locales/<tag>.txt` holds one catalog per locale; `<tag>` is
like `en`, `de` or `pt-BR`. `gweb` compiles them to `.gooseweb/t.goose`, and pages and layouts can call `t::` (a route, middleware or `lib/` file writes `import t;`).

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
import web;
import t;

fn before(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) -> bool {
    let i, ok = t::find(web::param(ctx, "lang"));
    if ok { ctx.locale = i; } else { web::not_found(ctx); return false; }
    return true;
}
```

Not in v1: translations inside `.gshtml` components (pass translated text in as data), number, date and currency
formatting, HTML inside messages, and decimal plural operands.

## Example

`../examples/shop` is the benchmark site: pages, a JSON API, a todo list in
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
<button on:click="inc">Clicked {s.count} times</button>
```

- The script needs `struct State`. Types: `i64`, `bool`, `u8[..N]`, structs
  of the block, and one `Name[>..<]` as the last field of `State`.
- A handler is a function whose first parameter is `s: State&`. Markup calls
  it with `on:click`, `on:change`, `on:input` or `on:submit`:
  `on:click="remove(t.id)"`; arguments are `i64`, `bool` or strings.
- `bind:value="field"` and `bind:checked="field"` tie an input to a direct
  `State` field.
- Templates work as in `page.html` (`{ }`, `{#raw }`, `{#if}`, `{#for}`,
  `{#let}`), except `@Name()`, `@slot()` and `@f()`.
- The client subset (E3) leaves out `match`, `enum`, floats, `loop`, `guard`,
  `defer`, blocks, closures, slices, `as`, bitwise operators, char literals,
  generics, globals and imports. Callable: the block's functions, `min`, `max`,
  `abs`, `str`, `web::has`, `push`, `remove_at`, `clear`, `append`, and `.len`.
  gweb reports anything else at its line, as `components/Name.gshtml:LINE: error:`.

**Embedding.** `@Name(expr)` in any page, layout or not-found
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
compact, and compares the state and the render byte for byte. Needs `node`. It generates into `.gooseweb.test/`, so a built
`.gooseweb/server` and a running `gweb dev` are untouched.
goose-web's own suite is `test/components.sh` (parity components in
`test/components/*.gshtml`, one `Fail*.gshtml` per error message, and a check that
`client/gwi.min.js` is current). `test/morph.sh` runs the DOM morph under jsdom (it installs jsdom
into `~/.cache/goose-web-test` on its first run).

**Maintainers.** After editing `client/gwi.js`, run `client/build.sh` (esbuild
0.28.2 through `npx`, or `ESBUILD=/path/to/esbuild`); it writes
`client/gwi.min.js` with the source's FNV-1a hash in its banner.

**Limits (v1).** A moved keyed element is reinserted, which reloads an iframe
inside it. Integers above 2^53 lose precision in the browser. Component
state lives in the page only. Handlers get no event data.

