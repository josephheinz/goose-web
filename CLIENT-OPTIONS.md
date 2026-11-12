<!-- Produced by goose-architect on claude-fable-5-2 -->
# Options study: a client side for goose-web

This is a study for the user to choose from; nothing is decided or implemented. Six options follow, then a comparison table and a recommendation.

## What I checked first

- **Goose has no WebAssembly or JS target.** `docs/design/wasm.md` opens with "This is a proposal and is not implemented"; its memory model (reserved address space per data stack) does not exist in Wasm.
- **The C route to Wasm fails today.** `goose -o tiny.c --standalone` on a three-line program gives 241 KB of C, and `clang --target=wasm32` stops at `'string.h' file not found`. No `wasm-ld`, `emcc` or wasi-sdk is installed.
- **Local tools:** node 24 and deno are installed; `elm`, `esbuild` and `bun` are not.
- **goose-web templates paste Goose expressions verbatim.** `compile_template` in `cli/gweb.goose` never parses an expression, so anything that must run an expression in the browser needs a new parser or translator.
- **goose-web does not compress responses**, so shipped bytes are raw bytes unless that is added.
- **Sizes for third-party libraries below are from memory**, not measured.

Baseline: the shop product page is about 840 bytes with no script; the Next page is about 6.9 KB of HTML plus React's bundles.

## Option A: progressive enhancement plus live reload only

- **How it works:** pages stay as they are; forms post and redirect; users write any script by hand in `public/`. `gweb dev` injects a small script that polls a build id and reloads when it changes.
- **Type safety:** all in Goose on the server. Hand-written scripts are unchecked.
- **Bytes on the product page:** 0 in production; about 200 bytes of reload script in dev only.
- **Work:** small, roughly 60–150 lines in gweb and `web.goose`. No new tools, no build-time change.
- **Scope creep:** none.
- **Not verified:** nothing prototyped; the dev endpoint design is a sketch.

## Option B: hypermedia fragments with a tiny goose-web runtime

- **How it works:** attributes such as `gw-post="/api/todos"`, `gw-target="#list"`, `gw-swap="append"` on ordinary HTML. The server answers with an HTML fragment rendered by a normal template, and the runtime swaps it in. gweb embeds the runtime and adds the script tag only on pages that use a `gw-` attribute.
- **Type safety:** only HTML crosses the wire, and it is rendered by type-checked Goose templates. gweb can check at build time that every `gw-*` URL matches a route with that method. Target selectors and form field names can drift.
- **Bytes:** I wrote a sketch covering get/post/put/delete, target, swap modes, forms, history push and dev reload: 1,906 bytes raw, about 1,670 crudely minified, 759 gzipped. The product page itself ships 0 extra bytes because it has no `gw-` attribute.
- **Work:** medium, roughly 400–600 lines: the runtime, a fragment convention (a template rendered without its layout), and the URL check. No new tools.
- **Scope creep:** low if v1 stops at request, target, swap and forms. It grows if client-side state, transitions or an expression language creep in.
- **Not verified:** the sketch was never run in a browser. htmx itself would work instead at about 16 KB gzipped (from memory), with no URL check.

## Option C: TypeScript islands with generated types

- **How it works:** `app/**/name.island.ts` (plain or Preact) mounted into a marked element in server HTML; props are serialized as JSON in the page; islands call JSON routes. gweb generates `.d.ts` types from Goose structs and route signatures, runs esbuild, and embeds the bundles.
- **Type safety:** `tsc` checks the client against generated types. Drift is possible wherever the generator and the hand-written JSON writers in routes disagree, unless JSON writers are generated too.
- **Bytes:** 0 on the product page; a page with a Preact island pays about 4–5 KB gzipped once (from memory), plus the island code and its props.
- **Work:** medium to large, roughly 600–900 lines, plus node and esbuild as build dependencies. Build and `gweb dev` gain a bundling step.
- **Scope creep:** moderate. The line is "islands only, no client router, no server-side rendering of islands".
- **Not verified:** how to extract Goose struct shapes. gweb does not parse Goose; compile-time reflection (`const for <N, A> in fields<T>`) might let a generated Goose program print the types, but I did not test that.

## Option D: Elm islands

- **How it works:** as option C, but islands are `Browser.element` programs in Elm; gweb generates Elm types and JSON decoders from Goose structs and runs `elm make --optimize`.
- **Type safety:** the strongest on the client, with no runtime exceptions in Elm code. The boundary is only as safe as the generated decoders; a mismatch fails at decode time, not compile time.
- **Bytes:** 0 on the product page; a small Elm island is roughly 7–10 KB gzipped after minifying (from memory).
- **Work:** medium to large, similar to C, plus the Elm compiler (not installed) and a minifier. Elm's compiler has had no release since 2019: stable, but frozen.
- **Scope creep:** moderate, same line as C. A second language for every contributor.
- **Not verified:** everything; Elm is not installed here.

## Option E: `.gshtml` components compiled to server Goose and client JS

- **How it works:** one file holds markup, state and event handlers. gweb compiles it to a Goose render function (as now) and to generated JS that hydrates marked islands and updates the DOM.
- **Type safety:** best in principle, one source checked by the Goose compiler. In practice the client half is a translation of Goose expressions to JS, so the translator's subset and semantics (integer overflow, bounds checks, strings as bytes) are the drift.
- **Bytes:** could be the smallest for interactive pages, on the order of 1–3 KB per page in the style of Svelte output (estimate, nothing built).
- **Work:** large and open-ended: an expression parser and translator, a reactivity model, event binding, state serialization, source maps for errors. Thousands of lines, and it never finishes.
- **Scope creep:** this is the "remaking React" option. A v1 line would be: no components calling components, state limited to flat structs, a fixed list of expression forms.
- **Not verified:** nothing prototyped.

## Option F: `.gshtml` with the client half in Goose compiled to WebAssembly

- **How it works:** as E, but handlers stay real Goose and run as Wasm with a JS shim for the DOM.
- **Type safety:** the best of all: the same language and types on both sides, no translation.
- **Bytes:** unknown; the runtime alone starts from 241 KB of C before optimization.
- **Work:** blocked on a compiler port that the Goose docs describe as unimplemented, plus a Wasm toolchain. Not something goose-web can do alone.
- **Scope creep:** very high; it means working on the compiler.
- **Not verified:** only that it does not build today.

## Comparison

| | A: enhance + reload | B: fragments | C: TS islands | D: Elm islands | E: `.gshtml` → JS | F: `.gshtml` → Wasm |
|---|---|---|---|---|---|---|
| Product page extra bytes | 0 | 0 | 0 | 0 | 0 | 0 |
| Interactive page cost | hand-written | about 1.7 KB once | about 4–5 KB gz + island | about 7–10 KB gz | about 1–3 KB (guess) | unknown, large |
| Boundary type safety | n/a | HTML only; URLs checkable | generated types | generated decoders | one source, translated | one source, native |
| Client-side state | no | no | yes | yes | yes | yes |
| New toolchain | none | none | node, esbuild | elm, minifier | none | Wasm toolchain + compiler port |
| Work | small | medium | medium–large | medium–large | large, open-ended | blocked |
| Scope-creep risk | none | low | moderate | moderate | high | very high |

## Recommendation (for the user to accept or reject)

Do A and B now, and hold C as the later escape hatch.

- **A is needed regardless.** Live reload was already deferred to v2 and every other option benefits from it.
- **B fits what goose-web is.** The server is the fast part (840 bytes, 230k req/s); fragments keep all logic in type-checked Goose, add no toolchain, and cost under 2 KB. The build-time URL check gives a kind of safety htmx cannot.
- **C only when a page needs real client state** (a cart that works offline, a drag-and-drop editor). It is the cheapest way to get typed client code without inventing a language.
- **I would not start E or F.** E is the user's own scope-creep worry made concrete, and F waits on the Goose compiler.
- **D over C only if the user specifically wants Elm**; it costs a second language and a frozen compiler for a modest gain in client-side safety.

The decision that is the user's: whether "lighter and faster than React" is worth owning a component compiler (E), or whether fragments plus occasional islands is enough.

Files: the runtime sketch is `/private/tmp/claude-501/-Users-joeheinz--claude-spares-spare-sGecwS/10d9fa68-9193-489c-9d6d-af48a0a097a1/scratchpad/client/gw.js`; the failed Wasm attempt is `tiny.goose` / `tiny.c` in the same folder.
