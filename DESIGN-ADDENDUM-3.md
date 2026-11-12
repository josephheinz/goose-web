<!-- Produced by goose-architect on claude-fable-5-2 -->

> **Rename (2026-11-12, the user's request):** islands are now called components. The text below keeps the old names. Read `islands/` as `components/`, `{{island Name(expr)}}` as `{{component Name(expr)}}`, `data-island` as `data-component`, `cli/island.goose` as `cli/component.goose`, `test/islands` as `test/components`, `--islands` as `--components`, and the `/islands` demo pages as `/components`.

> **Syntax changed (2026-11-12):** the template and markup tags in this file (`{{ e }}`, `{{{ e }}}`, `{{#if}}`, `{{component Name(e)}}`, `{{slot}}`, `{{> f()}}`) are replaced by DESIGN-ADDENDUM-6-SYNTAX.md. The text stays as history.
# Implementation spec: live reload (A) and `.gshtml` islands (E v1)

Build in the order A, E phase 1, 2, 3. Everything below is decided unless it is listed in section 8, where six defaults need the user's confirmation.

Checked while writing this (scratchpad `e_spec/`, plus the earlier `e_study/proto/`):
- Goose `%` is Euclidean, not C-like: `-7 % 3` is 2, `7 % -3` is 1, `-7 % -3` is 2. `/` truncates: `-7 / 3` is -2.
- `for i in n` evaluates its bound once; `for x in arr` copies fixed-size elements and Goose itself rejects writes to the copy.
- Appending past a `u8[..N]` capacity aborts ("limited array capacity exceeded").
- `str("a", 3, true)` gives `a3true` and assigns to a `u8[..N]` field.
- A never-called check function is still type-checked.

Not built: the parser, translator, `gweb test`, and the runtime in a browser.

## A. Live reload

**Mechanism:** the page polls a build id.

- `web.goose`: add `dev_id: i64` to `Config` (0 = off). `config_from_args` reads `--dev-id N`.
- `run_worker`, before calling `D`: if `cfg.dev_id != 0` and `req.path == "/__gweb/id"`, answer 200 `text/plain` with the id in decimal and `Cache-Control: no-store`. Do not log these requests.
- `run_worker`, after `D` returns: call `web::dev_inject(res, cfg.dev_id)`.

```goose
fn dev_inject(res: http::Response&, dev_id: i64)   // no-op unless dev_id != 0 and content_type starts with "text/html"
```

It appends to `res.body`:

```html
<script>(function(){var id="ID";setInterval(function(){fetch("/__gweb/id",{cache:"no-store"}).then(function(r){return r.text()}).then(function(t){if(t!==id)location.reload()}).catch(function(){})},500)})();</script>
```

- `cli/gweb.goose` `server_cmd(extra, dev)`: when `dev`, add ` --dev-id <time_ms()>` (a fresh value per spawn).
- `stamp()`: add `"islands"` to the watched folders.
- **Failed build:** the old server keeps its old id, so nothing reloads; errors stay in the terminal. While the server restarts, fetch fails silently and the next poll sees the new id.
- Production binaries never get the flag, so nothing is served or injected.

Done when: editing `page.html` reloads an open page within about a second; a broken edit does not reload; `gweb start` output contains no script.

## E1. Files, names, embedding

- **Location:** `islands/Name.gshtml` at the project root, flat. `Name` matches `[A-Z][A-Za-z0-9]*` and is not a JS reserved word.
- **Namespace:** `Name` itself. Goose output is `.gooseweb/Name.goose`, so `page.goose` may write `import TodoBox;` and use `TodoBox::State`.
- **File shape:** line 1 is exactly `<script goose>`; a line that is exactly `</script>` ends the block; markup follows. No `import` or `namespace` inside the block.
- **Required:** `struct State { … }`. Handlers are functions whose first parameter is `s: State&`. Markup refers to the state as `s`.
- **Embedding:** `{{island Name(expr)}}` in any `page.html`, `layout.html` or `not-found.html`. `expr` is a Goose expression of type `Name::State`, usually `props.todo_state`. It compiles to `Name::island(out, expr);`. An unknown `Name` is a gen error at that line.
- `add_default_imports` adds `import Name;` for every island.
- Not allowed inside a `.gshtml`: `{{island}}`, `{{slot}}`, `{{> f()}}`.

## E2. Pipeline and outputs

New file `cli/island.goose` (`namespace island;`, imported by `gweb.goose`):

```goose
struct Field { name: u8[..64], kind: Kind, struct_name: u8[..64], cap: i64 }
enum Kind { Int, Bool, Str, Struct, Array }           // Array: of struct_name
fn compile(name: const u8[:], path: const u8[:], src: const u8[:],
           goose_out: u8[>..]&, js_out: u8[>..]&, errs: u8[>..]&) -> bool
fn parse_script(path: const u8[:], lines: const u8[:][:], first_line: i64, errs: u8[>..]&) -> bool
fn compile_markup(path: const u8[:], lines: const u8[:][:], first_line: i64,
                  goose_out: u8[>..]&, js_out: u8[>..]&, check_out: u8[>..]&, errs: u8[>..]&) -> bool
fn emit_js_fn(i: i64, js_out: u8[>..]&)                // one parsed function
fn emit_json_writer(goose_out: u8[>..]&)
fn emit_zero(js_out: u8[>..]&)
```

`gweb.goose` gains `scan_islands()`, `gen_islands()` (called in `gen()` before the templates), a `{{island …}}` case in `compile_template`, and `test_cmd()`.

**Goose output `.gooseweb/Name.goose`**, line-for-line with the source:

| Source line | Output line |
|---|---|
| 1 `<script goose>` | `namespace Name; import std; import json; import web; import web.template;` |
| script lines | verbatim |
| `</script>` | `fn render(out: u8[>..]&, s: const State&) {` |
| markup lines | one line each, as `compile_template` does; `}` closes on the last |
| after the last source line | `gw_check`, `gw_json`, `island` |

`map.txt` gets `Name.goose\tislands/Name.gshtml`; a compiler error past the source's last line is reported as "generated code for islands/Name.gshtml".

Generated tail:

```goose
fn gw_check(s: const State&) { var w = State { .. }; /* markup's for/if/let nesting, with each on: call as name(w, args); */ }
fn gw_json(out: u8[>..]&, s: const State&)      // from the parsed struct declarations
fn island(out: u8[>..]&, s: const State&)
```

`island` writes `<div data-island="Name">`, the render, `</div><script type="application/json">`, `gw_json`, `</script><script type="module" src="/_gw/Name.js"></script>`.

New helpers in `template.goose`:

```goose
fn json_text(out: u8[>..]&, s: const u8[:])   // JSON string; <, > and & written as <, >, &
fn arg(out: u8[>..]&, v: i64)                 // digits
fn arg(out: u8[>..]&, v: bool)
fn arg(out: u8[>..]&, v: const u8[:])         // JSON string, then HTML-escaped
fn has(a: const u8[:], b: const u8[:]) -> bool
```

**Markup rewriting** (both backends):
- `on:EVENT="name"` or `on:EVENT="name(a, b)"` becomes `data-on-EVENT="name" data-args="[a,b]"`, each argument through `web::arg`. Events: `click`, `change`, `input`, `submit`. Arguments must be `i64`, `bool` or string.
- `bind:value="field"` becomes `value="{{ s.field }}" data-bind="field"`, plus `data-cap="N"` for a `u8[..N]` field.
- `bind:checked="field"` becomes `{{#if s.field}}checked{{/if}} data-bind="field"`.
- `field` is a direct `State` field of kind `Int`, `Bool` or `Str`.

**JS output `.gooseweb/_gw/Name.js`:** one module.

```js
import { island, esc, at, set, rm, blen, cap, idiv, imod } from "./gwi.js";
function add(s) { … }                    // every script function
function render(s) { let o = ""; … return o; }
function zero() { return { draft: "", next_id: 0, items: [] }; }
island("Name", { render, zero, handlers: { add, toggle }, tests: { test_basic } });
```

**Serving:**
- gweb copies `<goose-web>/client/gwi.js` to `.gooseweb/_gw/gwi.js`, dropping lines that are only a `//` comment and leading indentation.
- `gen_islands` pushes a `Static` for `/_gw/gwi.js` and each `/_gw/Name.js` (`file` = `.gooseweb/_gw/…`, `ctype` = `text/javascript; charset=utf-8`, the same FNV ETag). `gen_static` embeds them unchanged.
- One file per island plus the shared runtime; no bundling, no minifier.
- A `public/_gw/` folder is a gen error.

## E3. The subset

**Types:** `i64`, `bool`, `u8[..N]`, a struct declared in the block, and `Name[>..<]` / `Name[>..]` as the last field of `State` only. Parameter types: `State&`, `const State&`, `i64`, `bool`, `const u8[:]`, `const Name&`. Return types: `i64`, `bool`.

**Declarations:** `struct Name { f: T, … }` and `fn name(params) [-> T] { … }`. A function named `test_*` taking only `s: State&` is a parity test.

**Statements:**
- `let x = e;` and `var x = e;` (optional `: T`)
- `lv = e;`, `lv += e;`, `-=`, `*=`, `/=`, `%=`, `lv++;`, `lv--;`
- `if c { } else if c { } else { }`
- `for i in e { }`, `for i in a..b { }`, `for x in arr { }`, `for x, i in arr { }`
- `while c { }`, `return;`, `return e;`, `break;`, `continue;`
- a call as a statement; a final expression without `;` as the return value

**Expressions:** integer literals (at most 2^53), `true`, `false`, string literals (`\n \t \r \\ \" \'`, `\xNN` below 0x80), names, `a.f`, `a[i]`, `f(args)`, `Name { f: e, … }` with every field named, `!e`, `-e`, `* / %`, `+ -`, `< <= > >=`, `== !=`, `&&`, `||`, parentheses, and `if c { a } else { b }` with single-expression branches. Precedence is Goose's (Rust's); the emitter parenthesizes every binary operation.

**Type inference:** every expression is `Int`, `Bool`, `Str`, `Struct(Name)`, `Array(Name)` or void, from literals, declared fields, parameters, `let` initializers and loop variables (`for i in Int` gives `Int`; `for x in Array(N)` gives `Struct(N)`; the index is `Int`). An expression the translator cannot type is an error.

**JS rules:**

| Goose | JS |
|---|---|
| `a / b` | `idiv(a, b)`: `Math.trunc`, throws on 0 |
| `a % b` | `imod(a, b)`: Euclidean, throws on 0 |
| `+ - *` on ints | plain; no overflow check |
| `arr[i]` | `at(arr, i)`; `arr[i] = v` is `set(arr, i, v)`; both throw out of bounds |
| `arr.len` | `arr.length` |
| `arr.push(v)`, `arr.remove_at(i)`, `arr.clear()` | `arr.push(v)`, `rm(arr, i)`, `arr.length = 0` |
| struct value that is not a literal (push argument, right-hand side, `let`) | `{...v}` copy |
| `str.len` | `blen(str)` (UTF-8 bytes) |
| `lv.clear()` on a string | `lv = ""` |
| `lv.append(x)`, `lv = x` on `u8[..N]` | `lv = cap(lv + x, N)`; throws past N bytes |
| `==`, `!=` on ints, bools, strings | `===`, `!==` |
| `for i in e` | `for (let i = 0, n = e; i < n; i++)` |
| `min`, `max`, `abs` | `Math.min`, `Math.max`, `Math.abs` |
| `str(a, b, …)` | `"" + a + b …` |
| `web::has(a, b)` | `a.includes(b)` |
| `{{ e }}` | `esc(e)`; `{{{ e }}}` is unescaped |

**Errors** go to stderr as `islands/Name.gshtml:LINE: error: MESSAGE`. They do not stop gen: the build still runs the Goose compiler, prints both sets, and fails if either has errors. Messages:
- `'match' is not available in client code (islands v1)`; the same form for `enum`, `f64`, `loop`, `guard`, `defer`, blocks and closures, slices `a[x..y]`, `as`, bitwise operators, char literals, generics, globals, `import`
- `string indexing is not available in client code; compare or append whole strings`
- `'NAME' is not on the client whitelist (min, max, abs, str, web::has, push, remove_at, clear, append, len)`
- `comparing structs is not available in client code`
- `cannot tell the type of this expression; add a type to the let`
- `State may hold one array, as its last field`
- `on:EVENT handler 'NAME' is not a function taking s: State&`
- `bind:value needs a State field of type i64, bool or u8[..N]`
- `'NAME' is a reserved word in JavaScript; rename it`
- `integer literal is too large for client code (limit 2^53)`

## E4. Runtime `client/gwi.js`

Start from `e_study/proto/gen/gwi.js`.

**Public surface:** `island(name, def)`, `esc`, `at`, `set`, `rm`, `blen`, `cap`, `idiv`, `imod`.

**Events:** four capture-phase listeners on `document` (`click`, `change`, `input`, `submit`). For an event:
1. Find the nearest `[data-island]`, and the nearest `[data-on-TYPE]` or (for `input` and `change`) `[data-bind]`.
2. On first use, parse the state from `root.nextElementSibling.textContent` and keep it in a `WeakMap`.
3. Take a `structuredClone` of the state.
4. For a bind: checkbox gives `el.checked`; if the current value is a number, `Math.trunc(Number(v)) || 0`; else the string, ignored when `blen` exceeds `data-cap`.
5. For a handler: `preventDefault()` on `submit`, then `handlers[name](s, ...JSON.parse(el.dataset.args || "[]"))`.
6. If anything threw, restore the clone and `console.error`. Then re-render and morph.

**Morph:** walk old and new children in parallel. Different node type or tag: replace. Text: update `data`. Element: sync attributes, set `value` unless the element has focus, set `checked`, recurse. Append extra new nodes; remove extra old ones.

**Limits (documented, not fixed in v1):** no keys, so removing a list item reuses the following nodes and can move focus or selection within a list; DOM changed by other scripts inside an island is overwritten; no event data reaches handlers.

## E5. Parity harness: `gweb test`

- For each island gweb writes `.gooseweb/test/main.goose`: for every `test_*` function, `var s = Name::State { .. }; Name::test_x(s);`, then print `== Name test_x`, the `gw_json` line, the render, and `== end`. A case `zero` (no test function) is always added.
- Build with `goose build -o .gooseweb/test/islands_test`, run it into `.gooseweb/test/goose.out`.
- gweb writes `.gooseweb/test/run.mjs`: stub `globalThis.document = { addEventListener() {} }`, import each `../_gw/Name.js`, run `zero()` and each test, then compare the state by deep equality with the parsed Goose JSON and the render byte for byte. It prints the first differing line per case and exits 1 on any difference.
- gweb runs `node .gooseweb/test/run.mjs`. Without `node` on PATH: `gweb test needs node`.
- goose-web's own suite: `test/islands/*.gshtml`, run by `test/islands.sh`, covering:
  - every statement and expression form;
  - `/` and `%` with each sign combination;
  - strings with `& < > " '` and multi-byte UTF-8 (`len`, capacity);
  - `for` bounds evaluated once;
  - struct copy on push and `let`;
  - nested `{{#for}}` and `{{#if}}`;
  - each error message above, as expected-failure files.

E counts as done when that suite, `gweb test` in the shop, and the browser test in E7 all pass.

## E6. Phases

1. **Server side.** Scan, split, parser, `.gooseweb/Name.goose`, `{{island}}`, `gw_json`, `gw_check`. Done: the shop's island pages render as static HTML with the JSON block; a type error in a handler or an `on:` call is reported at its `.gshtml` line; unsupported forms give the errors above.
2. **JS and parity.** JS emitter, `zero`, `gweb test`. Done: `test/islands.sh` and the shop's `gweb test` pass.
3. **Runtime and serving.** `client/gwi.js`, `/_gw/` statics, events, binding, morph, rollback. Done: the browser test passes and `check_site.py` passes.

Typed route calls stay out; islands hold client-only state.

## E7. Demo in `examples/shop`

Benchmark pages stay unchanged. Add:
- `islands/Counter.gshtml`, `islands/TodoBox.gshtml` (from the prototype, plus a `test_basic` each), and `islands/Qty.gshtml`: quantity with + and − buttons and a total in dollars computed with integer `/` and `%`.
- `app/islands/page.goose` + `page.html` at `/islands`: Counter and TodoBox, with a line saying the list is not saved.
- `app/islands/products/[id]/page.goose` + `page.html`: the product with a Qty island seeded from its price.

`check_site.py` must show:
- `/islands` contains `data-island="Counter"`, `data-island="TodoBox"`, a JSON block and the module script tags.
- `/_gw/gwi.js` and `/_gw/TodoBox.js` return 200 as `text/javascript` with an ETag, and 304 on `If-None-Match`.
- `/products/42` is byte-identical to before.

Browser test, against `gweb dev`:
- Counter increments.
- Typing in the todo input keeps focus.
- Add, toggle and remove update the list and the "n of m left" line.
- Qty changes the total.
- A handler that throws leaves the page unchanged.
- An edit to a `.gshtml` reloads the page.
- Enter in the todo input adds the item and clears the input, which keeps focus (follow-up 2, point 3).
- A render that throws after a handler (`test/islands/RenderThrow.gshtml`) leaves the DOM unchanged and raises one `gw:error` (follow-up 2, point 7).
- After the `boom` click, the overlay is still visible two seconds later (follow-up 3).
- A click on the overlay removes it (follow-up 3).
- A build error shown while an island error is pending replaces it; fixing the build reloads the page, which clears the island errors (follow-ups 3 and 4).

## E8. Risks, and what to confirm with the user

Risks:
- **Parity drift:** any number or string rule missed by the suite is a silent server/client mismatch. `%` already differed from what the prototype assumed.
- **Subset pressure:** each added form needs a parser rule, a JS rule and a parity test.
- **Morph without keys:** list edits can move focus.
- **`gw_check` covers types only;** I saw no lifetime errors from never-called functions, so a handler call the lifetime checker would reject is not caught there (it never runs on the server, so this is harmless).
- **2^53:** ids above it corrupt silently on the client.

Defaults I chose that are the user's call; ask before building past them:
1. `gweb test` needs `node` (test time only, not build or run).
2. `f64` is out of v1 entirely, to avoid float formatting differences.
3. Generated JS and `gwi.js` ship unminified (no bundler dependency); about 2.6 KB raw for the runtime.
4. Build errors show in the terminal only; no in-browser overlay.
5. The demo lives on new `/islands` pages; the todo island does not persist, since route calls are out.
6. The folder name `islands/` and the `{{island Name(expr)}}` syntax.

Paths: prototype at `/private/tmp/claude-501/-Users-joeheinz--claude-spares-spare-sGecwS/10d9fa68-9193-489c-9d6d-af48a0a097a1/scratchpad/e_study/proto/`; the semantics checks at `…/scratchpad/e_spec/chk.goose` and `cap.goose`.

## Follow-up 1: minifier and browser error overlay

Both changes fit without adding a build dependency for app developers: gweb emits island JS already minified, the runtime ships as a committed minified file, and build errors reach the browser through the existing `/__gweb/id` endpoint. That endpoint's body format and the injected script change, so section A needs the update below before it is finished.

### 1. Minifier

**Decision: no minifier tool at app build time.** Two parts:

- **Island JS (`/_gw/Name.js`):** the translator emits it compact itself. It already knows every name and scope, so it needs no separate minify pass.
- **Runtime (`/_gw/gwi.js`):** hand-written, so it is minified once by goose-web maintainers with esbuild and committed as `client/gwi.min.js`.

**Modes**

| | `gweb dev` | `gweb build` / `gweb start` |
|---|---|---|
| Island JS | pretty: one statement per line, real names, a `// islands/Name.gshtml:LINE` comment above each function | compact: no optional whitespace or newlines; locals, parameters and top-level functions renamed to short names |
| Runtime | `client/gwi.js` copied as is | `client/gwi.min.js` copied as is |

- Struct field names are never renamed (they are JSON keys).
- Handler and test names stay as string keys in the object passed to `island(...)`.

**Signatures that change**

```goose
// cli/island.goose
fn compile(name: const u8[:], path: const u8[:], src: const u8[:], compact: bool,
           goose_out: u8[>..]&, js_out: u8[>..]&, errs: u8[>..]&) -> bool
// cli/gweb.goose
fn gen(dev: bool) -> bool          // dev picks pretty JS and client/gwi.js
fn build(debug: bool, dev: bool) -> bool
```

**Maintainer step:** `client/build.sh` runs

```
npx --yes esbuild@0.28.2 client/gwi.js --minify --format=esm --banner:js="/* gwi SRC_HASH */" --outfile=client/gwi.min.js
```

where `SRC_HASH` is the FNV-1a hash of `client/gwi.js`. `test/islands.sh` fails if the banner hash does not match the current source, so a stale minified file cannot ship.

**Source maps:** none in v1. Runtime errors are debugged in dev, where the JS is pretty and each function carries its `.gshtml` line. The helper errors (`at`, `cap`, `idiv`, `imod`) already carry readable messages.

**Parity:** `gweb test` runs every case twice, against pretty and compact output, so the shipped form is the tested form.

**Measured:** esbuild 0.28.2 takes the prototype runtime from 2,595 to 1,764 bytes (956 gzipped). For scale, esbuild takes the prototype `todobox.js` from 1,383 to 1,109 bytes; the translator's own compact output is not built, so its size is not measured.

**Rejected**
- esbuild or terser as a build dependency: it would make node and npm required for every goose-web app.
- Optional esbuild with a fallback: two shipped forms to test, for a gain of a few dozen bytes.
- A general JS minifier written in Goose: a second parser to maintain.

### 2. Error overlay (dev only)

**How errors reach the browser**

- gweb writes the error text to `.gooseweb.dev/errors.txt` in the project. This folder is separate from `.gooseweb/`, which `gen` wipes.
- `cli/gweb.goose`: `err()` and `build()` also append what they print to a new global `var last_errors: u8[>..];` (the rewritten `path:line: error:` text, island translator errors included, capped at 16 KB).
- In `dev()`:
  - at start, create `.gooseweb.dev/` and write an empty `errors.txt`;
  - on a failed build, write `last_errors` to it;
  - on a good build, write it empty before spawning the new server.
- `gweb new` adds `.gooseweb.dev/` to the scaffold's `.gitignore`, alongside `.gooseweb/`.

**Endpoint (this changes section A):** the path stays `/__gweb/id`. The body becomes the id on line 1, then the contents of `.gooseweb.dev/errors.txt` (nothing when the file is empty or missing). Still `text/plain`, `Cache-Control: no-store`, not logged, and only when `cfg.dev_id != 0`.

```goose
// web.goose
fn dev_status(res: http::Response&, dev_id: i64)   // writes the body described above
```

**Injected script (replaces the one in section A):**

```html
<script>(function(){var id="ID",fails=0,box;
function show(t){if(!box){box=document.createElement("pre");box.style.cssText="position:fixed;inset:0;margin:0;padding:24px;background:rgba(20,0,0,.92);color:#fff;font:13px/1.5 monospace;white-space:pre-wrap;overflow:auto;z-index:2147483647";document.body.appendChild(box)}box.textContent=t}
function hide(){if(box){box.remove();box=null}}
addEventListener("gw:error",function(e){show("island error\n\n"+e.detail)});
setInterval(function(){fetch("/__gweb/id",{cache:"no-store"}).then(function(r){return r.text()}).then(function(t){fails=0;var n=t.indexOf("\n"),cur=n<0?t:t.slice(0,n),errs=n<0?"":t.slice(n+1);if(cur!==id){location.reload();return}if(errs.trim())show("build failed\n\n"+errs);else hide()}).catch(function(){if(++fails>=4)show("gweb dev: the server is not responding")})},500)})();</script>
```

**Behaviour**
- A failed build shows the same errors as the terminal, as plain text (set through `textContent`, so nothing in it is interpreted as HTML).
- The next good build restarts the server with a new id, and the page reloads.
- Fixing the error without changing output still clears the overlay, because a good build empties the file.
- If the server is down for four polls, the overlay says so.

**Island runtime errors:** `client/gwi.js`, after rolling back a failed handler, also does `dispatchEvent(new CustomEvent("gw:error", { detail: String(err) }))`. In dev the script above shows it; in production nothing listens.

**Production:** no `--dev-id`, so no endpoint, no script, and `.gooseweb.dev/` is never read.

**Limit:** if the very first build fails there is no server yet, so the errors are in the terminal only.

### 3. What else changes in addendum 3

- **Section A:** endpoint body and injected script as above; `dev_inject` is unchanged in signature.
- **E2 serving:** drop the rule about stripping comment lines from `gwi.js`; copy `client/gwi.js` (dev) or `client/gwi.min.js` (build/start).
- **E4 runtime:** add the `gw:error` event.
- **E5:** `gweb test` runs both JS modes; `test/islands.sh` adds the stale-minified check.
- **E7 `check_site.py`:** in a production build, `/_gw/gwi.js` starts with the `/* gwi` banner and is at most 2,560 bytes (changed in follow-up 2).
- **E8 defaults:** 1 (node only for `gweb test`), 2, 5 and 6 stand. Maintainers, not app developers, additionally need `npx` to regenerate `gwi.min.js`.

Not built or run: the overlay script, `dev_status`, and the translator's compact mode.

### Correction on record: `json_text`

The comment in the spec was garbled in transit. `web::json_text` writes the characters `<`, `>` and `&` as the six-character JSON escapes: backslash, `u`, then `003c`, `003e` and `0026` respectively. That keeps a `</script>` inside a string from ending the JSON block.

## Follow-up 2: implementation questions

Decisions on the seven points, then the recorded choices. I read `client/gwi.js`, `check_site.py` and `bench_shop.py`; nothing was run or changed.

### 1. `check_site.py` gating

**Keep the `--islands` flag, and have `bench_shop.py` pass it when `kind == "goose"`.** The baseline file `goose-bench/shop/baseline/products_42.html` stays.

- Rejected, auto-detection: a goose site whose `/islands` broke would silently skip the checks.
- Rejected, flag left off in the benchmark: the benchmark would then run a site whose islands were never checked.

### 2. Error lines past an island's end

**Confirmed as implemented.** `// gw:line N` on each `gw_check` line, mapped to `islands/Name.gshtml:N`; other past-the-end errors keep "generated code for islands/Name.gshtml". This is what E6 phase 1 requires; E2's sentence was too broad.

### 3. Morph and the focused input

**Change the rule:** a focused control is overwritten only when the state behind it moved after the bind step.

In the listener, after the bind and before the handler:
- let `f` be `D.activeElement` if it is inside `root` and has `data-bind`, with key `k`;
- remember `before = s[k]`;
- set `force` when the bind was rejected for capacity, or when `s[k] !== before` after the handler.

In `morph`, the condition becomes `(a != D.activeElement || force) && a.value != b.value`.

What this gives:
- Enter in the todo input: `add` clears `s.draft`, so the input clears.
- Typing `1.` in a number field: state is 1 before and after, so the text is left alone.
- Text over capacity: the input reverts to the state's value (E4 said it is ignored; now that is visible).
- Unbound focused inputs are never overwritten.

Add a `Forms` browser-test line for Enter-to-add.

### 4. The size limit

**New limit: `client/gwi.min.js` is at most 2,560 bytes.** "Under 2 KB" was shorthand, not a requirement. Points 3 and 7 and the two fixes below add roughly 100–150 bytes (my estimate). Update the `check_site.py` assertion and the note in Follow-up 1.

### 5. String literals in `on:` arguments

**Accept single-quoted attribute values:** `on:click='say("x")'`. The markup scanner takes either quote for `on:` and `bind:` attributes; the output attributes are always double-quoted. No escape syntax. Add one parity case with a string-literal argument.

### 6. Messages

Confirmed as worded, with two changes:

- **`bind:checked`** gets its own message: `bind:checked needs a State field of type bool`.
- **End of input** should not use the "not available" form: `unexpected end of the <script goose> block`.

Confirmed unchanged:
- `on:EVENT arguments must be i64, bool or strings`
- `an island needs struct State { ... } in its <script goose> block`
- `an island starts with a line that is exactly <script goose>`, and the matching `</script>` message
- `no island named X (there is no islands/X.gshtml)`
- the `public/_gw` message
- the `'X' is not available in client code (islands v1)` form for block, closure, `a[x..y]`, generics, global, char literal, raw string, field defaults, and for `{{island}}`, `{{slot}}`, `{{> f()}}` inside an island

### 7. Render inside the try

**Move it inside, and return from the catch without morphing.**

```js
let html;
try { /* bind */ /* handler */ html = def.render(s); }
catch (err) { live.set(root, keep); console.error(err); dispatchEvent(...); return; }
/* template + morph(root, …) with html */
```

- A render that throws now rolls the state back and raises `gw:error`, like a handler.
- After a rollback the DOM already matches the kept state, so no morph is needed; the text the user just typed stays in the input.
- `force` from point 3 is computed only on the success path.

Add a test island whose markup indexes out of range after a handler, expecting unchanged DOM and one `gw:error`.

### Recorded choices

Accepted as they are:
- `structuredClone` for struct copies that hold structs or arrays.
- `gw_w` in `gw_check`.
- `gweb test` importing `./js-pretty` and `./js-compact` with a shim `gwi.js`.
- `$N` suffixes for name clashes in pretty mode.
- Compact mode importing only the helpers used, under short aliases.

Change these two:
- **Handler element outside the island.** `t.closest(sel)` can match an ancestor of the island that carries a hand-written `data-on-*`, which then calls a missing handler. Ignore `el` and `bound` unless `root.contains(...)` them.
- **Form-control sync order.** Value and `checked` are written before `morph(a, b)` recurses. For a `<select>` whose options change in the same update, the value is set before the new option exists. Move the sync after the recursion. The `"form" in a` test itself is fine.

<!-- goose-architect reply to the browser evidence for point 3 -->

The browser evidence matches the case point 3's rule was written for, so the decision stands unchanged: overwrite a focused control only when the state behind it moved after the bind step.

Tracing your exact case through the rule (by reading `client/gwi.js`; I have not run the changed runtime):

- **Event:** Enter fires `submit` on the form. Focus is still on the input, which is inside the island and has `data-bind="draft"`.
- **Before the handler:** `before = s.draft`, which is `"Enter test"`.
- **After `add`:** `s.draft` is `""`, which differs from `before`, so `force` is set.
- **Morph:** the condition `(a != D.activeElement || force) && a.value != b.value` is true for the input, so its value is cleared. Focus stays where it is, so the user can type the next item.

Clicking Add already worked because focus had moved to the button, and that path is unaffected.

One detail to get right when implementing: take the focused element from `D.activeElement` on every event type, not only on `input` and `change`. On `submit` the listener currently never looks for a bound element, so `before` must be read from the active element directly.

Add this as a browser-test line: type text, press Enter, expect the item in the list, an empty input, and focus still in the input.

## Follow-up 3: island errors in the dev overlay

You found a real gap: the poll's `hide()` removed island errors along with build errors. The fix is to keep two separate messages, so the poll only ever touches the build/server one.

**Behaviour**

- **Two slots:** `sys` (build failed, or server not responding) and `isl` (island errors). The overlay shows `sys` if it is set, otherwise `isl`, and is removed when both are empty.
- **Island errors stay** until the user clicks the overlay or the page reloads. The poll no longer clears them.
- **A later island error appends** on a new line under the first, so a handler that throws repeatedly shows each error.
- **Build and server messages take priority** while they last. A fixed build reloads the page, which clears island errors; only a server-not-responding message that clears without a reload lets undismissed island errors show again.
- **A click clears island errors only.** A build-failed overlay comes back on the next poll, which is intended: it should stay until the build is fixed.

**Replacement script** (replaces the one in Follow-up 1 section 2; `ID` is the build id as before):

```html
<script>(function(){var id="ID",fails=0,box,sys="",isl="";
function draw(){var t=sys||isl;if(!t){if(box){box.remove();box=null}return}
if(!box){box=document.createElement("pre");box.style.cssText="position:fixed;inset:0;margin:0;padding:24px;background:rgba(20,0,0,.92);color:#fff;font:13px/1.5 monospace;white-space:pre-wrap;overflow:auto;z-index:2147483647";box.onclick=function(){isl="";draw()};document.body.appendChild(box)}
if(box.textContent!==t)box.textContent=t}
addEventListener("gw:error",function(e){isl+=(isl?"\n":"island error (click to dismiss)\n\n")+e.detail;draw()});
setInterval(function(){fetch("/__gweb/id",{cache:"no-store"}).then(function(r){return r.text()}).then(function(t){fails=0;var n=t.indexOf("\n"),cur=n<0?t:t.slice(0,n),errs=n<0?"":t.slice(n+1);if(cur!==id){location.reload();return}sys=errs.trim()?"build failed\n\n"+errs:"";draw()}).catch(function(){if(++fails>=4){sys="gweb dev: the server is not responding";draw()}})},500)})();</script>
```

**Size:** the script body goes from 834 to 957 bytes, 123 more. It is inline and dev-only, so `gwi.min.js` and production pages are unaffected.

**What I checked:** the script passes `node --check`, and a Node simulation with a stubbed `document`, `fetch` and timer gave the expected result for each rule:
- an island error survives two clean polls;
- a second error appends;
- a build error replaces it while present;
- the island errors return when the build error clears;
- a click removes the overlay, and it stays removed on the next poll.

It has not been run in a browser.

**Nothing else changes:** the endpoint, `dev_status`, `dev_inject` and the `gw:error` event in `client/gwi.js` stay as specified.

**Browser test lines to add to E7:**
- After the `boom` click, the overlay is still visible two seconds later.
- A click on it removes it.
- A build error shown while an island error is pending replaces it; fixing the build reloads the page, which clears the island errors.

Prototype files: `/private/tmp/claude-501/-Users-joeheinz--claude-spares-spare-sGecwS/10d9fa68-9193-489c-9d6d-af48a0a097a1/scratchpad/f3/new.js` and `old.js`.

## Follow-up 4: island errors after a fixed build

**Decision: keep the behaviour, reword the test line.** The contradiction is in my E7 line, not in the script. A fixed build always restarts the server with a new id, so the page reloads, and a reload clearing island errors is correct: the island's state is reset too, so the old error no longer describes anything on the page.

The "island errors come back" path still exists in the script, but only where no reload follows: the server-not-responding message clearing when the server answers again with the same id. That is not worth a browser test line.

I did not change the behaviour to carry island errors across a reload; that would mean storing them outside the page for no benefit.

**Edits to `/Users/joeheinz/Documents/goose/goose-web/DESIGN-ADDENDUM-3.md`** (three places):

1. Line 240, in E7. Old:

```
- A build error shown while an island error is pending replaces it, and fixing the build brings the island error back (follow-up 3).
```

New:

```
- A build error shown while an island error is pending replaces it; fixing the build reloads the page, which clears the island errors (follow-ups 3 and 4).
```

2. Line 481, in Follow-up 3's behaviour list. Old:

```
- **Build and server messages take priority** while they last. When the build is fixed without a reload, any undismissed island errors show again.
```

New:

```
- **Build and server messages take priority** while they last. A fixed build reloads the page, which clears island errors; only a server-not-responding message that clears without a reload lets undismissed island errors show again.
```

3. Line 511, in Follow-up 3's browser test lines. Old:

```
- A build error shown while an island error is pending replaces it, and fixing the build brings the island error back.
```

New:

```
- A build error shown while an island error is pending replaces it; fixing the build reloads the page, which clears the island errors.
```

Line 501 ("the island errors return when the build error clears") describes my Node simulation, where the id was held constant, so it is accurate as written and stays.

Nothing in the code changes. The results you reported for Follow-ups 2 and 3 need no further decision from me.
