<!-- Produced by goose-architect on claude-opus-5-5 (medium) -->
# Design addendum 12: component reactivity and client interactivity (goose-web v0.3)

Scope: everything under "Client interactivity" in `docs/BACKLOG.md`. The reactivity study (sections 1 to 6) comes first and the backlog items are designed against it (section 7). Cross-cutting items are in section 8, the byte budget in section 9, migration in section 10, the build plan in section 11.

Other architects: section 8.1 (the warning channel) and section 9 (the runtime split and the byte budget) affect you. Read them first.

## What I read, and the evidence

Read: `docs/BACKLOG.md`, `ARCHITECTURE.md`, `CLIENT-OPTIONS.md`, Addenda 3, 6, 9 and 11, the CSRF parts of Addendum 7, `cli/component.goose` (parser, checker, JS emitter, markup compiler, `compile`), `cli/gweb.goose` (`err`, `gen`, `gen_components`, `build`, `test_cmd`, `dev`, flags), `cli/tscan.goose` usage, `client/gwi.js`, `client/build.sh`, `web.goose` (`dev_status`, `dev_inject`), `test/components.sh`, `test/morph.sh`, `test/morph_test.mjs`, `test/release_check.sh`, the `test/components/*.gshtml` corpus.

Facts the decisions rest on:

- **The client subset is closed.** No closures, no globals, no function values, no dynamic dispatch (Addendum 3, E3). Every read and write of component state is visible to `cli/component.goose` at build time. This is what makes compile-time dependency tracking possible without runtime signals.
- **The compiler already resolves every name** (`lookup`, `declare`, scopes) and types every expression (`check_expr`). Dependency sets are a new pass over the same AST.
- **The Goose output is verbatim today** (script lines copied unchanged). Reactive code cannot stay verbatim: `count += 1` must become `gw_s.count += 1` in Goose. Token offsets exist (`Tok.s`, `Tok.e`), so a line-preserving token rewrite is possible.
- **Components resume, they do not hydrate.** State JSON is parsed on the first event (`live` WeakMap). Nothing runs at load.
- **`morph` is the only DOM writer** (Addendum 9). Keyed morph is tested under jsdom: `test/morph.sh` passes 21 cases here (jsdom 31.0.0, node 26).
- **No goose compiler is on this machine.** `npx esbuild@0.28.2` and jsdom work.
- **Measured runtime sizes** (esbuild 0.28.2, this machine, scratchpad sketches):

| Build | Minified bytes | gzip |
|---|---|---|
| `gwi.min.js` today (with banner) | 3,604 | |
| `gwi.js` without the fragment code (`frag`), plus `export{swap,oops}` | 2,697 | 1,448 |
| fragment code alone, importing `swap`, `oops` | 943 | 601 |
| core without fragments, plus the reactive contract of section 5 (sketch) | 3,573 | |
| the same, plus modifiers, lifecycle, fetch, child props and emit, all in core (sketch) | 5,182 | |

  The last row is over 4,096. That fixes the shape of section 9: fragments and every feature beyond the core contract move into optional modules.

## 1. Syntax inside `<script goose>`

A component is **reactive** when its script has an `@` declaration, **legacy** when it declares `struct State`. Both in one file is an error.

```goose
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

Declarations:

| Form | Meaning | Types allowed |
|---|---|---|
| `@prop const NAME: T;` or `= LITERAL;` | input from the parent; read-only | `i64`, `bool`, `u8[:]`, `u8[..N]`, a struct `S`, `S[:]` |
| `@state var NAME: T = EXPR;` | local state; handlers assign it | `i64`, `bool`, `u8[..N]`, a struct, `S[>..<]` (initializer `[]`) |
| `@computed let NAME: T = EXPR;` | derived; the framework rebinds it | `i64`, `bool`, `u8[..N]`, a struct |
| `@watch { ... }` | runs again when state it reads changes | |
| `@mount { ... }`, `@unmount { ... }`, `@every(MS) { ... }` | lifecycle (section 7.2) | |
| `@event fn NAME(params);` | an event the component sends to its parent (section 7.6) | |
| `@use Store;` | read a shared store (section 7.7) | |

Rules:

- **Explicit types (user rule).** A `@prop`, `@state` or `@computed` without `: T` is an error: `@state count needs a type: write @state var count: T = ...`. No inference, also in `gweb dev`.
- **Binding keywords (user rule).** The marker decides the meaning; the keyword is checked. `@prop let`/`var` build with `a prop should be const`; `@computed const`/`var` with `a computed value should be let`; `@state let`/`const` with `state should be var`. `--strict` makes them errors.
- **Prop defaults** are literals only. A prop without a default is required at every call site.
- **`@state` initializers** may read props and earlier `@state`. A later one is an error: `@state a reads b, which is declared after it`.
- **`@computed`** may read props, state and other computeds in any order; the compiler sorts them. A cycle is an error: `@computed a and b depend on each other`. A computed may call functions that only read state, never one that writes or awaits.
- **Writes.** Assigning a prop, or writing into it, is an error: `@prop label is const; a component cannot change its props`. Assigning a computed is an error: `@computed doubled is set by the framework; component code cannot assign it`.
- **Names.** Reactive names live at module level. A parameter or local with the same name is an error (`'count' is @state; a local cannot reuse the name`). Names starting with `gw_` are reserved. At most 31 reactive names (props, state and computed together) per component: `a component may have at most 31 @prop, @state and @computed names` (one bit each in a JS integer).
- **Handlers** are plain functions: `fn inc()`, `fn add(id: i64)`. Nobody writes `s: State&`. Parameters stay `i64`, `bool`, `const u8[:]`.
- **Tests** are `fn test_*()` with no parameters. Props are zero (`0`, `false`, `""`, empty) in tests.
- **Markup** names state directly: `{count}`, `{#for t in items}`. `s.` does not exist in reactive components. `on:` and `bind:` keep their quoted forms: `on:click="inc"`, `on:click="add(t.id)"`, `bind:value="draft"`. `bind:` needs a `@state var`; a prop or computed is an error.

## 2. Dependency tracking at compile time

Each reactive name gets a bit, in declaration order. A new pass after `check_fn` computes for every function, computed, watch and markup part:

- **R**, the bits it reads, through calls (a fixed point over the call graph).
- **W**, the bits it writes. A write is an assignment, `+=` and the like, `++`/`--`, `push`/`remove_at`/`clear`/`append`, or a write into contents (`items[0].done = true`, `p.x = 1`). Passing a reactive value to a mutable struct parameter (`T&`) writes the whole name.
- **async**, when it contains `await` or calls an async function.

From these:

- A function with W non-empty gets the state mutably; with only R, read-only; with neither, nothing. Goose: `gw_p: const Props&, gw_s: State&` (or `const State&`). JS: `(s, c, ...)` when it writes, awaits or emits, else `(s, ...)`, else `(...)`.
- After every write statement the JS has `c.m(BITS)`: the user's setter idea, with the bit known at build time. Writes into contents and `&` passing mark the whole name.
- Markup, computeds and watches may not call a function that writes or awaits: `@computed doubled cannot call 'inc', which changes state`. A watch may write (section 7.1).
- The server render runs no setters and no watches: `gw_init` and `render` only.

## 3. What the compiler emits

### 3.1 Goose (server render and type checking)

Script lines stay line for line, so Goose errors still point at the `.gshtml` line. Edits are recorded during checking as (offset, length, replacement) and applied per line:

| Source | Goose on the same line |
|---|---|
| `@prop const x: T;` | empty |
| `@state var x: T = e;` | `fn gw_i_x(gw_p: const Props&, gw_s: const State&) -> T { return e'; }` (array state: empty) |
| `@computed let x: T = e;` | `fn gw_c_x(gw_p: const Props&, gw_s: const State&) -> T { return e'; }` |
| `@watch {` (and `@mount`, `@unmount`, `@every(n)`) | `fn gw_w0(gw_p: const Props&, gw_s: State&) {` |
| `@event fn change(v: i64);` | `fn change(v: i64) {}` |
| `fn inc() {` | `fn inc(gw_p: const Props&, gw_s: State&) {` |
| a name that resolves to a prop | `gw_p.label` |
| a name that resolves to state or computed | `gw_s.count` |
| a call of a state-taking function | `f(gw_p, gw_s, ...)` |
| `await` | removed |
| `http::get(u)` (section 7.3) | `gw_get_K(u)`, a typed stub in the tail |

Tail, after the last source line:

```goose
struct Props { label: const u8[:], start: i64, step: i64 }   // u8[:] -> const u8[:], S[:] -> const S[:]
struct State { count: i64, doubled: i64 }                     // state and computed; an array last
fn gw_init(gw_p: const Props&) -> State                       // state in order, then computeds sorted
fn gw_flush(gw_p: const Props&, gw_s: State&)                 // every computed, sorted (gweb test)
fn render(out: u8[>..]&, gw_p: const Props&, gw_s: const State&)   // the markup lines, as today
fn gw_check(...)                                              // as today, with gw_p and gw_s
fn gw_json(out: u8[>..]&, gw_p: const Props&, gw_s: const State&)  // one object: props, state, computed
fn component(out: u8[>..]&, gw_p: const Props&)               // div, render, JSON script, module script
```

Props stay in their own struct, passed by `const` reference from the page, so a `u8[:]` prop is never stored in a returned `State` (no lifetime question, and the one-array rule of `State` is not spent on strings).

Pages call a reactive component with named arguments: `@Counter(start: 3, label: p.name)`. gweb fills defaults and emits `Counter::component(out, Counter::Props { label: p.name, start: 3, step: 1 });`. Errors: `@Counter needs prop start`, `Counter has no prop stat`. `@Counter()` works when every prop has a default. Legacy components keep `@Name(expr)` with one `Name::State` expression.

### 3.2 Parts and markers

A **part** is a dynamic place in the markup outside every `{#if}` and `{#for}`:

| Part | Source | Server HTML | Update |
|---|---|---|---|
| text | `{e}` | `<!--g-->` escaped value `<!---->` | the text node after the marker |
| attribute | an open tag with `{...}`, `bind:` or `on:` arguments that read state | `<!--g-->` before `<tag` | the element's whole attribute list |
| block | `{#if}...{/if}`, `{#for}...{/for}`, `{#raw e}` | `<!--g-->` content `<!--/g-->` | keyed morph between the two markers |

- The end marker `<!---->` of a text part is left out when a tag follows directly.
- A top-level `{#let}` is not a part. Parts after it that use its name depend on its R.
- Everything inside a block is part of the block. Blocks do not nest at the top level, so the markers never nest.
- A `{e}` directly inside `<textarea>` is an error: `use bind:value on <textarea>` (comments are text there).
- The compiler tracks whether it is inside an open tag, across lines, so a `{#if}` inside a tag is an attribute part.
- Full renders (Goose `render`, JS `r`) emit the markers, so parity covers them.

### 3.3 JS module

```js
import{component as C,esc as e,T,A,B}from"./gwi.js";
function inc(s,c){s.count+=s.step;c.m(8)}
function r(s){let o="";...;return o}                  // full render, markers included
function u(s,m){                                      // phase 1: computeds and new values; may throw
  if(m&8){s.doubled=s.count*2;m|=16}
  const a=m&2&&""+s.label,b=m&8&&""+s.count,d=m&16&&""+s.doubled;
  return(p,root,f)=>{m&2&&T(p[0],a);m&8&&T(p[1],b);m&16&&T(p[2],d)}   // phase 2: DOM writes only
}
function w(s,m,c){if(m&10)log(s.label,s.count)}       // watches, after the DOM writes
function i(p){...}                                     // props -> full state (children, tests)
C("Counter",{r,u,w,i,h:{inc},b:{label:2,start:1,step:4,count:8,doubled:16},p:7,e:"click",t:{test_inc}});
```

- `h` handlers, `b` name to bit, `p` prop bits, `x` async handlers' write masks (section 7.3), `e` event types used, `t` tests.
- Two phases keep the v0.2 guarantee: if anything in phase 1 throws, state rolls back and the DOM is not touched.
- Inside a block, the new HTML string comes from the same code that `r` uses, inlined in `u`.

## 4. Server rendering of the same component

`component(out, p)` runs `gw_init(p)` then `render`, then writes `gw_json` (props, state and computed in one object). No watch, mount or setter runs on the server. The client parses the JSON on first use, as today, so a computed is never recomputed at resume.

## 5. Runtime contract (`client/gwi.js` core)

Reference code (the sketch measured above; the builder may tighten it):

```js
function state(root) {
  let s = live.get(root);
  if (!s) live.set(root, s = JSON.parse(root.nextElementSibling.textContent));
  return s;
}

// One dispatch: bind, handler, update, watches. A sync throw restores the copy; an async throw
// restores the names the handler writes (def.x) and shows the rollback.
function run(root, def, name, args, e, bound) {
  const s = state(root), keep = structuredClone(s);
  const f = D.activeElement, k = root.contains(f) && f.dataset.bind;
  let m = 0, force = 0, before;
  const c = { m: (b) => m |= b, f: () => flush(0), r: root };
  const flush = (x) => {
    const b = m; m = 0;
    let go;
    try { go = def.u(s, b); } catch (err) { return fail(err); }
    go(anchors(root), root, force);
    def.w?.(s, b, c);
    hooks.a?.();
    if (m && x < 8) flush(x + 1); else if (m) oops("watch loop in " + root.dataset.component);
  };
  const fail = (err) => { /* restore keep (all, or def.x[name] bits); oops(err); flush the restored bits when async */ };
  try {
    /* bind as today, then m |= def.b[k] */
    before = k && s[k];
    if (name) { const r = def.h[name](s, c, ...args); r?.then?.(() => flush(0), fail); }
  } catch (err) { return fail(err); }
  if (k && s[k] !== before) force = 1;
  flush(0);
}

const parts = new WeakMap();
function anchors(root) {   // the root's own "g" comments in document order, not those of nested components
  let p = parts.get(root);
  if (!p) {
    parts.set(root, p = []);
    const w = D.createTreeWalker(root, 128);
    for (let n; n = w.nextNode();) if (n.data == "g" && n.parentNode.closest("[data-component]") == root) p.push(n);
  }
  return p;
}
const tpl = (h) => { const t = D.createElement("template"); t.innerHTML = h; return t.content; };
export const T = (a, v) => { const n = a.nextSibling; n.nodeType == 3 ? n.data != v && (n.data = v) : a.after(v); };
export const A = (a, v, f) => patch(a.nextSibling, tpl("<" + a.nextSibling.nodeName + " " + v + ">").firstChild, f, 1);
export const B = (a, v, f) => { let z = a; do z = z.nextSibling; while (z.data != "/g"); morph(a.parentNode, tpl(v), f, a, z); };
```

- **`morph(from, to, force, s, z)`** gains an optional range: the children after `s` and before `z`. `patch(o, b, force, top)` is the element case split out of `morph` (attribute sync, recursion unless `top`, form `value`/`checked`), shared by `A`. The keyed algorithm of Addendum 9 is unchanged.
- **`hooks`**: an exported object that optional modules fill. `morph` calls `hooks.c?.(o, b)` before patching an element whose old and new nodes are roots of the same component (section 7.5); `run` and `swap` call `hooks.a?.()` after DOM writes (lifecycle, section 7.2); `morph` calls `hooks.t?.(n, in)` on keyed inserts and removals (section 7.11). Core cost about 40 bytes.
- **Exports for modules:** `run`, `state`, `defs`, `hooks`, `swap`, `oops`, `morph`, plus the helpers.
- **Legacy defs** (`render`, `handlers`) get `u = (s) => (p, r, f) => swap(r, render(s), f)` and `h` wrappers at `component()` time, so one dispatch path serves both models until legacy goes.
- **Listeners:** one capture listener per event type, registered by `component()` for `def.e` plus the v0.2 four (section 7.2 item 2 extends this).

## 6. Goose and JS parity

- **`gweb test` (node only).** For reactive components the Goose side runs `var p = Name::Props { .. }; var s = Name::gw_init(p); Name::test_x(p, s); Name::gw_flush(p, s);`, then prints `gw_json` and `render`. The JS side runs `s = def.i()`, `def.t.test_x(s, c)` with a stub `c`, `def.u(s, ALL)` (recompute only), then `def.r(s)`. State and render must match byte for byte, pretty and compact, as today.
- **DOM parity (goose-web's own suite, jsdom).** `test/reactive_test.mjs` puts a component's server HTML in a jsdom page, dispatches real events through `gwi.js`, and checks that the root's `innerHTML` equals `def.r` of the final state. This is the check that fine-grained updates equal a fresh render. It runs on hand-written defs from step 3 on, and on compiled defs once a goose compiler is available (`GOOSE` set).

## 7. The backlog items against this model

### 7.1 Item 4: derived values

Covered by `@computed`. `fn view(s) -> View` is not added. **`@watch`** runs after the DOM writes when its R meets the dirty bits, and once at start (section 7.2). A watch may write state; the runtime runs another round, at most 8, then reports `watch loop in Name`. A throwing watch reports `gw:error` and rolls nothing back (the DOM already shows the handler's result).

### 7.2 Item 1: lifecycle and timers

- `@mount { ... }` runs once when the component starts on the client. `@unmount { ... }` runs when its root has left the document. `@every(MS) { ... }` runs every MS milliseconds while mounted (MS is an integer literal of at least 16).
- A component with `@watch`, `@mount`, `@unmount`, `@every` or `@use` **starts eagerly**: its module imports `life` from the optional `gwl.js` and calls it after `component()`. `life` materializes the state of every root of that name, runs watches with all bits and the mount block through `run`, and starts the intervals. Every other component stays lazy (resumable).
- `gwl.js` sets `hooks.a`: after any DOM write it starts new roots of eager components (from a fragment or a parent block) and runs `@unmount` for roots that left the document; intervals stop themselves when `root.isConnected` is false.
- Each lifecycle block runs through `run`, so its writes mark, flush and roll back like a handler. It may be async.
- Backlog wording was `fn mount(s: State&)` and `every(ms, handler)`. Blocks match `@watch` and need no handler wiring (open question 5).

### 7.2b Item 2: more events and modifiers

- `on:EVENT.MOD.MOD="handler(args)"`. Events: `click`, `dblclick`, `change`, `input`, `submit`, `keydown`, `keyup`, `focus`, `blur`. Another `[a-z]+` name builds with the warning `unknown on: event 'x'` and is still wired.
- Modifiers: `prevent`, `stop`, a debounce `Nms` (1 to 10000), and key filters for `keydown`/`keyup` only: `enter`, `escape`, `space`, `tab`, `up`, `down`, `left`, `right`, `backspace`, `delete`. Any other modifier is an error: `unknown modifier .x on on:keydown`.
- Markup: `data-on-keydown="add.enter.prevent"`. The runtime splits on `.`; `prevent` and `stop` apply at once; a debounce defers only the handler (a `bind:` still applies at once).
- `focus` and `blur` work with capture listeners on `document`.

### 7.3 Item 3: async handlers with typed fetch

- `x = await http::get("/api/items");`, `let r: T = await http::get(u);`, `await http::post(u, v);` and `x = await http::post(u, v);`. The target's declared type is the reply type, so a `let` needs `: T`.
- `await` is required before `http::` calls and before calls of async functions (`'load' is async: write await load()`). Markup and computeds cannot call async functions.
- **Decoder:** generated per reply type in the component's JS. It checks integers (`Number.isInteger`, at most 2^53), bools, strings (and `u8[..N]` capacity in bytes), structs (every field; extra keys ignored), arrays. A mismatch throws `bad reply from /api/items at .items[2].title`.
- **Goose side:** `http::get(u)` becomes a stub `gw_get_K(u) -> T` in the tail, so the URL and the target type are type-checked. Handlers never run on the server.
- **Routes write the same types.** gweb adds `fn gw_json(out, v: const S[:])` for every struct, so a route answers with `Name::gw_json(res.body, items)` after `web::json(res, status)`.
- **URL check:** a string literal URL must match a route with that method, like `gw-target` (`http::get: no route GET /api/x`).
- **`gwh.js`** (optional) holds `get`, `post` and the error path. POST sends JSON with `X-CSRF-Token` taken from the page's `input[name=_csrf]` (written by `@web::csrf_field(ctx)`), which Addendum 7 accepts.
- **Failure** (network, status, decode): the handler stops. Its write set (`def.x[name]`, known at build time) is restored from the copy taken at its start, the restored bits flush, and `gw:error` is raised. Writes by other handlers in the meantime survive.

### 7.4 Item 9: optimistic updates (designed with item 3)

An async handler that writes, then awaits a `http::post`, is optimistic: the write shows at once, and a refusal rolls back exactly the names it wrote. This is the handler rollback reused. Fragment forms outside components keep server state only, so they have nothing to roll back (open question 7).

### 7.5 Item 5: nested components with reactive props

- `@Child(start: count, label: "x")` becomes legal inside a `.gshtml` (named arguments, as on pages). In a `{#for}`, `key: e` sets `gw-key` on the child root; without it the build warns `a component in {#for} needs key:`.
- The parent's Goose render calls `Child::component(out, Child::Props {...})`. The parent's JS imports the child's module and renders a new child with `Child.r(Child.i(props))`.
- A child call at the top level is a part; inside a block it is rendered with the block.
- **`gwc.js`** sets `hooks.c`: when `morph` meets an old and a new root of the same component, it does not recurse. It reads the new props from the new root's JSON, writes changed props into the old child's state, and runs the child's update with those bits. The child keeps its own state.

### 7.6 Item 6: child-to-parent events

- The child declares `@event fn change(v: i64);` and calls `change(qty);`. The parent writes `@Qty(start: 1, on:change="picked")`; `picked` must take parameters matching the declaration (`on:change handler 'picked' must take (i64)`).
- Markup: the child root carries `data-emit-change="picked"`. The call compiles to `c.e("change", [v])`; `gwc.js` finds the parent root and calls `run(parent, def, "picked", args)`.
- Backlog wording was `emit("change", value)`. A declared, typed event lets the parent's handler be type-checked (open question 4).

### 7.7 Item 7: shared stores

- `stores/Cart.gshtml` holds only a `<script goose>` block with `@state`, `@computed` and functions. `@store(local: "cart")` above the first declaration syncs it to `localStorage`.
- A component writes `@use Cart;` and reads `Cart::count`, calls `Cart::add(id)`. Store names get bits in the reading component.
- Server: the store renders from its initializers; its JSON is written once per page, before the first component that uses it.
- Client: `_gw/Cart.js` holds the store state and a subscriber list; components using a store start eagerly and subscribe. A store write marks the store's bits in every subscriber and flushes each.

### 7.8 Item 8: client navigation

- `<body gw-boost>` opts in. **`gwn.js`** (optional; gweb adds it when a layout has `gw-boost`) intercepts same-origin link clicks without `gw-target`, `download`, `target` or a modifier key, fetches the page with `GW-Nav: 1`, parses it with `DOMParser`, sets `document.title`, morphs `<body>`, imports module scripts not loaded yet, and pushes history. `popstate` does the same without a push.
- A component root with the same `gw-key` and name on both pages is kept as it is (persistent, its state survives).
- Scroll goes to the top, or to the `#hash` target.
- A reply that is not `text/html` or not 2xx becomes a normal navigation.

### 7.9 Item 10: server push

- `gw-sse="/events"` on an element. **`gwe.js`** (optional) opens an `EventSource`. An event `fragment` with data `NAME\nHTML` morphs `#NAME`; an event `store` with data `Store\nJSON` writes the store's state.
- The server half needs streaming responses, which goose-web lacks (`BACKLOG.md`, "Streaming responses"). Only the client half and the message format are built here (open question 8).

### 7.10 Item 11: transitions

- `gw-enter="fade-in"` and `gw-leave="fade-out"` on keyed elements. **`gwt.js`** (optional; gweb adds it when markup uses them) sets `hooks.t`: an inserted element gets the enter class until its `animationend`/`transitionend`; a removed one is kept with the leave class and `gw-leaving`, and removed at its end event or after 1 s. `morph` removes a `gw-leaving` element at once when it morphs that parent again.

## 8. Cross-cutting

### 8.1 gweb warnings (this addendum owns the channel)

- **Text format:** `path:line: warning: message` on stderr, the Goose compiler's own format. The build goes on. A summary line on stdout: `gweb: built ... (2 warnings)`.
- **API in `cli/gweb.goose`:** `fn warn(path: const u8[:], line: i64, code: const u8[:], msg: const u8[:])`, beside `err`. Both go through one `diag(sev, path, line, code, msg)`. `component::compile` gains a `warns: u8[>..]&` buffer in the same text format, with the code in a `\t`-separated prefix that gweb strips.
- **`--strict`:** after everything is printed, warnings above zero fail the build: `gweb: --strict: 2 warnings stop the build`. For `gen`, `build`, `start` and `test`.
- **`--diagnostics json`:** stderr becomes JSON Lines, one object per diagnostic: `{"severity":"warning","file":"components/X.gshtml","line":3,"code":"prop-keyword","message":"a prop should be const"}`. Goose compiler output is parsed by the `path:line[:col]: (error|warning): message` pattern; other lines are appended to the previous object's `"detail"`. Stdout is unchanged.
- **`gweb dev`:** warnings go to `.gooseweb.dev/warnings.txt`. `dev_status` answers `id\nERRORS\fWARNINGS`. The overlay shows warnings in a small box at the bottom right (`max-height: 30vh`), never full screen, dismissed by a click and shown again after the next build if still present. Build errors keep the full-screen overlay.
- **Codes:** `prop-keyword`, `computed-keyword`, `state-keyword`, `unkeyed-for`, `computed-no-state`, `watch-no-state`, `state-unused`, `unknown-event`, `unknown-attribute`, `child-key`, `legacy-state`.
- **No suppression comments in v1** (open question 10).
- **`release_check.sh`** runs the suites' expected-clean builds with `--strict`.

Other architects: call `warn` with a new code; do not add a second channel.

### 8.2 Type-checked markup

Warnings, in pages and components: an attribute name outside the HTML list (global, per-element, `data-*`, `aria-*`, `gw-key`, `gw-target`, `gw-boost`, `gw-enter`, `gw-leave`, `gw-sse`) gives `unknown-attribute`; an inline `onclick=`-style attribute in a component gives `use on:click`. Elements with `-` in the name (custom elements) are not checked. Event names: section 7.2b.

### 8.3 Other warnings

- `unkeyed-for`: a `{#for}` over a `@state` array (or a legacy `State` array) that the code writes other than by `push` and `clear`, whose element children lack `gw-key`. Page templates are not checked (their lists come from the server).
- `computed-no-state`, `watch-no-state`: R is empty.
- `state-unused`: a `@state` that no markup part, computed, watch or handler reads.

### 8.4 Parity tests

Every step below adds `test/components/*.gshtml` parity cases (string parity, `gweb test`) and, where it touches the DOM, jsdom cases in `test/reactive_test.mjs`.

## 9. Byte budget

**Decision:** the core stays under 4,096 bytes by moving code into optional ES modules, loaded only by pages or components that use them. A component module imports what it needs (`import{get}from"./gwh.js"`); gweb adds page-level modules (`gwf.js`, `gwn.js`, `gwe.js`, `gwt.js`) as `<script type="module">` tags only on pages that use their attributes.

| File | Holds | Ceiling (minified, with banner) | Estimate |
|---|---|---|---|
| `gwi.min.js` | helpers, morph, dispatch, parts, events and modifiers, hooks | 4,096 | about 3,850 |
| `gwf.min.js` | fragments (`gw-target`) | 1,536 | 943 today |
| `gwh.min.js` | `http::get`, `http::post` | 512 | about 250 |
| `gwl.min.js` | eager start, mount, unmount, every | 768 | about 350 |
| `gwc.min.js` | child props, events | 768 | about 300 |
| `gwn.min.js` | client navigation | 1,536 | about 900 |
| `gwt.min.js` | transitions | 768 | about 400 |
| `gwe.min.js` | server push | 768 | about 350 |

Per feature, in the core: section 5 contract about +876 over the 2,697 split core (measured sketch); modifiers and dynamic listeners about +150 net; hooks about +40. Per-component JS grows with parts; the builder measures the shop-sized fixtures and records the numbers in the build log.

- `test/runtime.sh` (node only) enforces every ceiling and the banner hash of every module.
- `client/build.sh` minifies every `client/gw*.js` that is not `.min.js`.
- Fragment pages now load `gwf.js` and, through its import, `gwi.js`: one more request. gweb adds `<link rel="modulepreload" href="/_gw/gwi.js">` with it.
- **For the other architects:** the core is reserved for this addendum. Fragment features (CSRF headers, error swaps, loading states) go into `gwf.js` within its ceiling. A new client feature gets its own module.

## 10. Migration of `struct State` components

1. **v0.3 builds both models** through one runtime path (section 5). Nothing breaks.
2. **By hand, per component** (the shop has three):
   - Each `State` field the page seeds becomes `@prop const seed_x: T;` plus `@state var x: T = seed_x;`. Other fields become `@state var x: T = ZERO;`. Arrays become `@state var items: Item[>..<] = [];`.
   - Derived helper functions used in markup (`left(s)`, `dollars(s)`) may become `@computed let`.
   - Drop `s: State&` and `s: const State&` parameters and every `s.` prefix, in the script and the markup.
   - `fn test_x(s: State&)` becomes `fn test_x()`.
   - The page call `@TodoBox(props.todo_state)` becomes `@TodoBox(seed_items: ...)` with named props, or `@TodoBox()`.
   - `bind:` and `on:` attributes do not change.
3. **The `legacy-state` warning** (`struct State components are deprecated; see DESIGN-ADDENDUM-12 section 10`) is added after the shop is migrated. The shop lives in the lab repository, outside this addendum's folders.
4. **Removal** of the legacy path, its shim and its tests is the user's call (open question 3).

`test/components/*.gshtml` (the v0.2 corpus) stays as the legacy suite; reactive cases are new files named `R*.gshtml` and `FailR*.gshtml`.

## 11. Build plan

Every step: edit only in this worktree, commit locally, never push. Check `$GOOSE` and `PATH` for a goose compiler. Without one, write the code and the tests, run what node can run, and say in the commit message what was not compiled. Steps 1 and 4 to 10, 12 and 13 change Goose code and cannot be compiled here.

**Step 1. Warning channel (8.1) and `unkeyed-for` for legacy components.**
Files: `cli/gweb.goose` (`diag`, `warn`, flags `--strict`, `--diagnostics json` for `gen`/`build`/`start`/`test`, usage), `cli/component.goose` (`warns` buffer, `unkeyed-for`), `web.goose` (`dev_status`, `dev_inject` warning box), `test/components.sh` (warning cases), `test/release_check.sh` (`--strict` where builds must be clean), `README.md` (flags).
Tests: `test/components/Warn*.gshtml` with `// warn: ` lines: the build succeeds and prints the line; with `--strict` it fails; with `--diagnostics json` each stderr line parses as JSON with the five keys (checked by node).
Done: the cases above are written; `node --check` passes on the changed overlay script.

**Step 2. Runtime split (9).**
Files: `client/gwi.js` (fragment code out, `swap` and `oops` exported), `client/gwf.js` (new), `client/build.sh` (all modules), minified files, `cli/gweb.goose` (embed and serve `gwf.js`; fragment pages get the `gwf.js` script and the modulepreload link), `test/runtime.sh` (new: banner hashes, ceilings, then `test/morph.sh`), `test/components.sh` (its banner check moves to `runtime.sh`), `test/fragments.sh` (script tag).
Done: `client/build.sh` and `test/runtime.sh` pass; sizes recorded.

**Step 3. Runtime contract (5).**
Files: `client/gwi.js`, minified file, `test/reactive_test.mjs` (new, jsdom), `test/runtime.sh` (runs it).
Tests (hand-written defs shaped like section 3.3): text, attribute and block parts update; untouched parts are the same nodes; a focused bound input keeps its text; a phase-1 throw leaves state and DOM unchanged; an async handler's rejection restores only its `x` bits and shows the rollback; watches run on their bits only; a watch that always writes stops after 8 rounds with one `gw:error`; a legacy def still works; after every case the root's `innerHTML` equals `def.r(state)`; `test/morph.sh` still passes.
Done: `test/runtime.sh` passes; `gwi.min.js` is at most 4,096 bytes.

**Step 4. Compiler front and Goose output (1, 2, 3.1).**
Files: `cli/component.goose` (declarations, types, keyword warnings, R/W/async pass, all section 1 errors, the edit list and the Goose tail), `cli/gweb.goose` (named-argument component calls; props list from `component::compile`), `test/components/R*.gshtml`, `FailR*.gshtml`, `WarnR*.gshtml`.
JS for reactive components is emitted as a placeholder module until step 5.
Done: every section 1 error and warning has a fixture; legacy output is byte-identical (no legacy fixture changes).

**Step 5. JS output, parts, markers, parity (3.2, 3.3, 6).**
Files: `cli/component.goose` (tag tracking, parts, markers in both backends, `c.m` marks, `r`, `u`, `w`, `i`, def table), `cli/gweb.goose` (`gweb test` for reactive components), `test/components/R*.gshtml` (parity: text, attribute and block parts; computed chains; watches; `{#let}`; strings with `& < >` and UTF-8).
Done: fixtures written; `gweb test` would run them; `test/runtime.sh` passes.

**Step 6. Item 3 and item 9: async handlers and typed fetch (7.3, 7.4).**
Files: `client/gwh.js`, `cli/component.goose` (`await`, async pass, decoders, stubs, `x` masks), `cli/gweb.goose` (`gw_json` slice overloads, URL check), `test/reactive_test.mjs` (fetch stubbed: success, status error, bad reply, rollback of the write set while another handler's write survives).
Done: jsdom cases pass; `gwh.min.js` within its ceiling.

**Step 7. Item 1: lifecycle and eager start (7.1, 7.2).**
Files: `client/gwl.js`, `cli/component.goose` (`@mount`, `@unmount`, `@every`, the `life` call), tests in `reactive_test.mjs` (fake timers: every ticks and stops when the root leaves; mount once; unmount after a fragment swap removes the root; a watch runs at start).

**Step 8. Item 2: events and modifiers (7.2b).**
Files: `client/gwi.js` (dynamic listeners, modifiers, debounce), `cli/component.goose` (event list, modifiers, warnings, errors), fixtures, jsdom cases (enter filter, prevent, stop, debounce with fake timers, focus and blur).

**Step 9. Item 5: nested components (7.5).**
Files: `client/gwc.js`, `client/gwi.js` (hook call in `morph`), `cli/component.goose` (child calls), `cli/gweb.goose` (component order: children compile first), fixtures, jsdom cases (prop update keeps child state; a new child in a keyed list renders from props; reorder keeps state).

**Step 10. Item 6: child events (7.6).**
Files: `client/gwc.js`, `cli/component.goose`, fixtures, jsdom cases.

**Step 11. Item 8: client navigation (7.8).**
Files: `client/gwn.js`, `cli/gweb.goose` (`gw-boost` detection, script tag), jsdom cases with a stubbed `fetch` and `history`.

**Step 12. Item 7: stores (7.7).**
Files: `cli/gweb.goose` (scan `stores/`), `cli/component.goose` (store compile, `@use`), store runtime in the generated store module, fixtures, jsdom cases (two subscribers, `localStorage`).

**Step 13. Type-checked markup and the remaining warnings (8.2, 8.3).**
Files: `cli/tscan.goose` or a new `cli/html.goose` (attribute lists), `cli/gweb.goose`, `cli/component.goose`, fixtures for each code.

**Step 14. Item 11: transitions (7.10).** `client/gwt.js`, the `hooks.t` calls, gweb script tag, jsdom cases.

**Step 15. Item 10: server push, client half (7.9).** `client/gwe.js`, gweb script tag, jsdom cases with a stub `EventSource`.

**Step 16. Docs.** `docs/ARCHITECTURE.md` (sections 4 and 7), `README.md` (component syntax, warnings, modules), `CHANGELOG.md`.

## 12. Rejected alternatives

- **Runtime signals or proxies.** The subset has no closures or dynamic calls, so the build already knows every edge. Signals cost runtime bytes (a graph, subscriptions) and would have to be serialized for resumption.
- **Keep whole re-render and morph, add only computeds.** Against the user's direction.
- **Static write masks per handler instead of marks after writes.** Inexact for conditional writes: watches would run when nothing changed. Static masks are still used for async rollback, where over-approximation is safe.
- **One global dirty accumulator.** Two async handlers resuming in turn would flush each other's bits into the wrong root. The per-dispatch `c` has no such race.
- **Svelte-style per-item blocks in `{#for}`.** Create, update and destroy code per block and per item multiplies component JS and compiler work. Keyed morph inside a block region gives stable identity today (open question 2).
- **Addressing nodes by child-index paths.** Whitespace and blocks shift indexes; comment markers do not.
- **Hydrating every component at load.** Loses resumption. Only components that need time-based or reactive start work start eagerly.
- **Keywords without `@` (`prop const x`, `state x`, `watch {}`).** New words in Goose syntax inside components; `@` already marks framework features.
- **`$` spelling, `derived`, `effect`.** User rules.
- **Copying props into `State`.** A `u8[:]` prop stored in a returned struct raises lifetime questions and spends the one-array rule.
- **Keeping fragments in the core.** 943 bytes that component-only pages do not need, and the 4,096 ceiling cannot hold both.
- **Warnings as a second stream of plain text with its own format.** Tools already parse `path:line: severity: message`.

## 13. Risks

- **Nothing in the compiler can be compiled here.** Steps 1, 4 to 10, 12 and 13 land as unbuilt Goose. The first build with a compiler will find errors. The JS runtime steps are tested under jsdom.
- **Goose assumptions not verified:** module-level declaration order (the tail declares `State` after the script uses it, as `gw_check` already does), `Props { .. }` with slice fields, returning `u8[..N]` from a string literal, and a struct with `const u8[:]` fields passed by `const` reference (the scaffold's `Props` does this).
- **Markers cost page bytes:** about 16 per text part, 8 per attribute part, 17 per block.
- **A block re-renders as a whole string** and morphs; a long list re-renders on any change to state it reads.
- **jsdom is not a browser** for focus and `template` parsing details.
- **Other architects edit `gwi.js`, `gweb.goose` and `web.goose` in parallel;** merges are likely around `gen`, `test_cmd`, `dev_status` and the fragment code that moves to `gwf.js`.

## Open questions for the user

Each has the default I build with.

1. **`on:click="inc"` keeps quotes.** The backlog illustration wrote `on:click={inc}`. Default: quotes only, as v0.2.
2. **Granularity inside `{#if}`/`{#for}`.** Default: a block updates as one region through keyed morph; text and attributes outside blocks update one node each.
3. **Legacy `struct State` components.** Default: both models in v0.3; the deprecation warning after the shop migrates; removal is your call.
4. **Child events.** Default: `@event fn change(v: i64);` called as `change(v)`, in place of `emit("change", v)`, so the parent's handler is type-checked.
5. **Lifecycle spelling.** Default: `@mount { }`, `@unmount { }`, `@every(ms) { }` blocks, in place of `fn mount(s: State&)` and `every(ms, handler)`.
6. **Fetch failures.** Default: no try/catch in the subset; a failure stops the handler, rolls back its writes and raises `gw:error`.
7. **Optimistic updates.** Default: async component handlers (7.4); fragment forms are unchanged.
8. **Server push.** Default: client half only, until streaming responses exist.
9. **Stores** live in `stores/Name.gshtml` (script only). Default as written.
10. **Warning suppression.** Default: none in v1; `--strict` means fix it.
11. **The component root stays a `<div>`.** Inside `<ul>` or `<table>` a child component needs a wrapper cell.
12. **One array `@state` per component**, as v0.2's one array in `State`. Default: unchanged.
13. **Fragment pages load two modules** (`gwf.js` and `gwi.js`). Default: accepted, with a modulepreload link.
