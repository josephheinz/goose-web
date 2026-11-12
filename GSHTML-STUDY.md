<!-- Produced by goose-architect on claude-fable-5-2 -->
# Deep study: option E, `.gshtml` compiled to server Goose and client JS

This is a study for the user to decide on. Short version: writing the compiler is not that bad if it copies the server template compiler's shape instead of Svelte's. A prototype of that shape works: about 1.1 KB gzipped for a counter and 1.5 KB for a todo list, with handlers type-checked by the real Goose compiler.

One gap up front: I did not install Svelte or Solid. They are not in the npm cache, installing downloads from the registry, and I need the user's own go-ahead for a download rather than an agent's. So the Svelte, Solid and React figures below are from memory, not measured.

## 1. How Svelte 5, Solid and the React Compiler work (from memory)

- **Svelte 5:** state is declared with runes (`$state`, `$derived`). The compiler turns each component into JS that clones a `<template>`, finds the dynamic nodes, and registers effects that update exactly those nodes when a signal changes. No virtual DOM. A counter ships a few KB gzipped of signal and template runtime.
- **SolidJS:** JSX compiled by dom-expressions into template cloning plus `createEffect` calls; components run once and signals drive updates. Similar size class to Svelte 5.
- **React Compiler:** a build step that adds memoization automatically. It still ships all of React and its virtual DOM (tens of KB gzipped), so it is not a model for a small runtime. Its useful lesson is that it bails out on code it cannot handle rather than guessing.

**Which fits goose-web:** none of them directly. The expensive part of Svelte and Solid is fine-grained updating: generated DOM-walking code, dependency tracking, hydration markers, keyed list reconciliation. goose-web already has a template compiler that emits string appends, so the cheapest client is the same compiler with a second backend: render the island to an HTML string in JS, then patch the live DOM with a small morph function. That is closer to Elm or LiveView's client than to Svelte. The cost is that an update re-renders the whole island, not one node, which is fine for islands of a few hundred nodes.

## 2. The translator problem and the "emit twice" idea

The idea holds, and is simpler than proposed. The `<script goose>` block is real Goose, copied verbatim into the generated server file. So:

- **Handlers are type-checked by the Goose compiler** as part of the normal build. In the prototype a bad handler was reported at its own line (`expected a value of type i64, got const u8[:]`).
- **Event wiring is checked too.** gweb emits each `on:click="toggle(t.id)"` once as a Goose call inside a never-called function; a wrong argument type gave `no matching overload for call to toggle`. Uncalled functions are still checked.
- **Helpers work on the server.** `left(s)` runs natively during server rendering.

The JS side then needs a parser for a fixed subset of Goose. Where it breaks:

| Area | Problem | v1 rule |
|---|---|---|
| Integers | JS numbers are exact only to 2^53; Goose signed overflow aborts in debug builds | client ints are JS numbers; ids above 2^53 are out |
| Division | Goose `/` on integers truncates; JS does not | translator must know operand types, so it needs small type inference; emits `Math.trunc` |
| Strings | Goose strings are bytes, JS strings are UTF-16; `.len`, indexing and slicing differ | whole-string operations only; `.len` via a byte-length helper; no indexing or slicing |
| Capacity | `u8[..200]` aborts past 200 bytes; JS has no limit | server stays the authority; `maxlength` on inputs |
| Bounds | Goose aborts out of bounds; JS returns `undefined` | index through a helper that throws |
| Structs | Goose copies struct values; JS aliases objects | no binding a struct to a local; mutate through index paths |
| Enums, `match` | need tagged-union encoding in JS and JSON | out of v1 |
| Narrow ints (`i32`, `u8`) | wrapping differs | only `i64`, `f64`, `bool`, strings in client state |
| Library calls | each needs a JS twin with identical behaviour | whitelist of about a dozen (`push`, `remove_at`, `clear`, `append`, `len`, `min`, `max`…) |

Anything outside the subset is a compile error ("not available in client code"), the React Compiler's bail-out approach.

One finding against a shortcut: reflection cannot write the state JSON generically. `fields<T>` rejects `u8[..200]` fields and `const if` has no query to tell a string from a struct, so gweb must generate the JSON writer from the struct declarations it parses.

## 3. A minimal v1 `.gshtml`

```html
<script goose>
struct Item { id: i64, title: u8[..200], done: bool }
struct State { draft: u8[..200], next_id: i64, items: Item[>..<] }
fn add(s: State&) { ... }
fn toggle(s: State&, id: i64) { ... }
fn left(s: const State&) -> i64 { ... }
</script>
<form on:submit="add">
<input name="draft" bind:value="draft" maxlength="200">
<button>Add</button>
</form>
<ul>
{{#for t in s.items}}
<li><input type="checkbox" {{#if t.done}}checked{{/if}} on:change="toggle(t.id)"> {{ t.title }}</li>
{{/for}}
</ul>
<p>{{ left(s) }} of {{ s.items.len }} left</p>
```

- **File:** one file is one island; a `<script goose>` block, then markup in the existing `{{ }}` syntax.
- **State:** one struct named `State`: `i64`, `f64`, `bool`, fixed-capacity strings, and one array of flat structs as the last field. (A Goose `root struct` allows several arrays; I did not test it here.)
- **Handlers:** `fn name(s: State&, args…)`. Events are `on:click`, `on:change`, `on:input`, `on:submit`; arguments are rendered into a `data-args` attribute, so the same markup works from server and client.
- **Two-way binding:** `bind:value` and `bind:checked` only.
- **Use in a page:** `{{island TodoBox(expr)}}` in `page.html`; the generated Goose writes the wrapper, the rendered HTML, and the state as JSON in a `<script type="application/json">` (with `<` escaped).
- **Hydration:** none at load. The runtime adds four document-level listeners; an island's state is parsed on its first event. This is resumption in the Qwik sense, without lazy-loading code.
- **Calling routes:** phase 2. Typed fetch needs typed routes on the server first (today's handlers write JSON by hand), which is a separate feature.
- **Out of v1:** islands inside islands, client routing, transitions, fine-grained updates, keyed lists, async in handlers, enums and `match`, client-only state rendered on the server.

## 4. Prototype

Hand-written outputs of what gweb would generate, in `/private/tmp/claude-501/-Users-joeheinz--claude-spares-spare-sGecwS/10d9fa68-9193-489c-9d6d-af48a0a097a1/scratchpad/e_study/proto/` (`TodoBox.gshtml`, `Counter.gshtml`, `gen/todobox.goose`, `gen/todobox.js`, `gen/counter.js`, `gen/gwi.js`, `parity.mjs`).

- **Goose side:** `goose check` passes; the script block sits on its original lines and the render function is one line per markup line, as templates are today.
- **Parity:** the JS render of the same state is byte-identical to the Goose server render, initially and after add, toggle and remove run on both sides (escaping included).
- **Sizes**, minified with the terser bundled in Next:

| File | Raw | Minified | Gzip |
|---|---:|---:|---:|
| `gwi.js` runtime (events, morph, helpers), shared | 2,595 | 1,769 | 941 |
| `todobox.js` | 1,383 | 1,116 | 582 |
| `counter.js` | 236 | 193 | 165 |

So a counter page costs about 1.1 KB gzipped and the todo page about 1.5 KB. Svelte 5's counter is, from memory, a few KB gzipped; I could not measure it.

Not run: the runtime's morph and event code in a real browser. The browser pane would not script a local file, so only the render and handler logic is verified (in Node).

## 5. Estimate

| Part | Goose lines (rough) |
|---|---:|
| `.gshtml` splitting, namespaces, line maps, `{{island}}` in pages | 250 |
| Template compiler with two backends, `on:` / `bind:` rewriting | 350 |
| Goose-subset tokenizer and parser (structs, functions, statements, expressions) | 700 |
| Small type inference for the subset | 250 |
| JS emitter and builtin whitelist | 350 |
| State JSON writer generator | 200 |
| Parity test harness (render and handlers on both sides) | 400 |
| **Total** | **about 2,500** |

Plus about 120 lines of runtime JS. gweb is 1,101 lines today, so this roughly triples the CLI.

Phases:
1. Expressions and render parity.
2. Handlers, runtime, events and binding.
3. State handoff and page embedding.
4. Typed route calls, after typed routes exist.

Hardest parts:
- Keeping number and string behaviour identical on both sides.
- Holding the subset: every user will want one more Goose feature.
- Server calls: Goose has no async, so the handler model needs a design.
- Morph edge cases: focus, selection, list reordering without keys.

Maintenance cost: every Goose language change touching the subset needs a matching translator change, and the parity suite is the only guard.

The line that keeps it from becoming React: one file is one island, whole-island re-render, a closed subset with compile errors outside it, and no component tree.

## 6. Verdict (for the user to accept or reject)

E is reasonable for goose-web in this reduced form, and not in the Svelte-like form.

- **Order: A, then B, then E.** A (live reload) helps everything. B (fragments) needs no compiler and covers server-driven interaction. E's runtime reuses B's pieces (delegated events, and the morph can serve B's swaps), so B is not wasted work.
- **Build E when a real page needs client-only state**, and start with the parity harness, since that is what makes the translator trustworthy.
- **If the user wants E sooner**, it can precede B at the cost of about 2,500 lines before any page benefits.

Risks:
- The subset grows until it is a second Goose implementation.
- A silent number or string mismatch between server and client.
- Whole-island re-render becomes slow on large lists, forcing keyed updates and with them much of Svelte's complexity.

Not verified:
- Svelte, Solid and React sizes and exact compiled output (from memory).
- The morph and event runtime in a browser.
- `root struct` as island state.
- Any part of the parser or translator; the outputs were written by hand.

To close the Svelte gap, someone with the user's OK can run `npm install svelte esbuild` in `/private/tmp/claude-501/-Users-joeheinz--claude-spares-spare-sGecwS/10d9fa68-9193-489c-9d6d-af48a0a097a1/scratchpad/e_study/sv`, compile the same counter and todo, and measure with `proto/size.cjs`.
