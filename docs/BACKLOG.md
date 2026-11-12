# Backlog

Ideas that have no design yet. Each item needs a design addendum from the architect before a builder starts. Order within a tier is the suggested build order.

## Client interactivity

Goal: cover most day-to-day Svelte and React use while the runtime stays small.

**Direction (user, 2026-11-12):** move component reactivity toward Svelte 5 and away from React. Use declaration markers in the spirit of Svelte runes, with goose-web's own spelling and names (see the rules below). The compiler tracks which template parts depend on which state, and it updates only those DOM nodes. It does not re-render the whole component and then morph. The items below must be designed against this direction. An architect study goes first: syntax inside `<script goose>`, dependency tracking at compile time versus signals at runtime, runtime byte cost, Goose and JS parity, server rendering of the same component, and migration of the current `struct State` components.

**Not a copy of Svelte (user rule):** take Svelte's model, not its spelling. The syntax follows goose-web's own conventions:
- `@` marks framework features, as `@Component()`, `@slot()` and `@ns::f()` already do. Do not use `$`.
- Reactive declarations stay normal Goose declarations (`let` and `var` with types), with a marker added. They are not function calls that wrap a value.
- Template blocks keep the `{#...}` and `on:` and `bind:` forms.
- Binding keywords (user choice): `@prop const`, so a component cannot rebind a prop or write into its contents. `@state var`, because handlers assign it. `@computed let`, because component code cannot assign it, but the framework rebinds it when its inputs change. `const` would suggest a fixed value.
- Other binding keywords build with a gweb warning (user choice): `@prop let` or `@prop var` ("a prop should be `const`"), `@computed const` or `@computed var` ("a computed value should be `let`"), and `@state let` or `@state const` ("state should be `var`"). `--strict` turns them into errors.
- Names (user choice): `@prop` for inputs from a parent, `@state` for local state, `@computed` for values derived from other state, `@watch` for blocks that run again when the state they read changes. Do not use Svelte's `derived` or `effect`.

Candidate shape for the architect to weigh (illustration only):

```goose
<script goose>
@prop const start: i64;
@prop const label: u8[:];
@state var count: i64 = start;
@computed let doubled: i64 = count * 2;
@watch { log(label, " is ", count); }
fn inc() { count += 1; }
</script>
<button on:click={inc}>{label}: {count} × 2 = {doubled}</button>
```

Alternative: keywords with no marker (`prop const start: i64;`, `state count: i64 = start;`, `computed doubled: i64 = count * 2;`, `watch { ... }`). This is shorter, but it adds new words to Goose syntax inside components.

**Tracking idea (user, to weigh first):** dependencies resolved at compile time, with no runtime signals or proxies. gweb sees every write to a `@state var` in the component and emits a generated setter call after it, for example `count = v; set_dirty(0)`. The compiler builds the dependency graph at build time: which `@computed`, `@watch` and template nodes read each state var. It emits one update function per component that recomputes computeds in topological order, patches only the dependent nodes, then runs the dependent watches. `gwi.js` gains only a small batcher, so several writes in one handler cause one flush. Most of the new code lands in the per-component JS files. Open points:
- Writes into contents (`items[0].done = true`) and passing state by `&` to a function mark the whole var dirty.
- A cycle between computeds is a build error.
- The server render runs no setters and no watches.
- Byte cost: the batcher in `gwi.js`, plus the per-component update code against today's whole re-render and morph.

**Explicit types (user rule):** every `@prop`, `@state` and `@computed` declaration states its type inline, with no inference, in development too. The build refuses an untyped declaration. The reason: a reader sees the type at once. The example above follows this rule.

Suggested order: 3, 1, 2, 5, 6, 8.

### Tier 1: high value, small runtime cost

1. **Lifecycle and timers.** `fn mount(s: State&)` and `fn unmount`, plus `every(ms, handler)`. Today only user events update a component. Use cases: clocks, polling, auto-save, animation.
2. **More events and modifiers.**
   - `keydown` with key filters, for example `on:keydown.enter`.
   - `blur` and `focus`.
   - Debounce, for example `on:input.300ms`.
   - `preventDefault` and `stopPropagation` modifiers.
3. **Async handlers with typed fetch.** A handler calls a route, for example `await http::get("/api/x")`, and puts the result into `State`. The response decoder is generated from the Goose type, so the network boundary stays type-checked. Components can then load data without a fragment.
4. **Derived values.** Computed fields or `fn view(s: State&) -> View`, evaluated before each render.

### Tier 2: composition

5. **Nested components with reactive props.** A parent's re-render updates the child's props and keeps the child's own state, through keyed morph and a component key.
6. **Child-to-parent events.** `emit("change", value)` in the child, and `on:change` on the child tag.
7. **Shared stores.** A page-level store that more than one component reads. A change re-renders each subscriber. Optional `localStorage` sync.

### Tier 3: SPA-level features

8. **Client navigation.** Link clicks fetch the next page and morph the body or layout slot. Persistent components are kept (like htmx `hx-boost` or Turbo).
9. **Optimistic updates.** A fragment form updates local state at once and rolls back if the server refuses. This reuses the existing handler rollback.
10. **Server push.** SSE, for example `gw-sse="/events"`, feeds fragments or a store, for live views without polling.
11. **Transitions.** Enter and leave classes on keyed elements during the morph.

### Cross-cutting

- **gweb warnings.** gweb has no warning channel today; it only fails a build with an error. Add one in the Goose compiler's own format, `file:line: warning: message`, on stderr, plus `--diagnostics json`. Add `--strict` to treat warnings as errors, for CI and `release_check.sh`. `gweb dev` shows warnings in the overlay without blocking the page. First candidates: the binding keyword warnings above, an unkeyed `{#for}` whose list can reorder (deferred in Addendum 9), a `@computed` that reads no state, a `@watch` that reads no state, a `@state` that the template and handlers never read, and an unknown `on:` event name.
- **Size budget.** Give each feature a byte budget against the 4,096-byte `gwi.min.js` limit, or split the features into optional modules that load only on pages that use them.
- **Type-checked markup.** Check event names and attribute names at build time, the way TSX does.
- **Parity tests.** Every new feature gets Goose and JS output parity tests in `gweb test`.

## Other gaps noted against Next.js and Blazor

- Auth and signed sessions. Deferred in Addendum 5; CSRF tokens in v0.2.0 do not cover it.
- Static generation and caching.
- Streaming responses.
- Image and metadata helpers.
- `loading` and `error` route files.

## Production readiness

Gaps against larger frameworks, ecosystem aside. Suggested next five after v0.2.0 and the reactivity study: auth and sessions (above), validation, error pages and boundaries, the static asset pipeline, Linux and Docker builds.

### Needed by most real apps

- **TLS, HTTP/2 and compression.** Serve them directly, or document a reverse proxy setup.
- **Static asset pipeline.** Hashed filenames, long cache headers and ETags for `public/`. Optional CSS and JS minification.
- **Config and secrets.** `.env` files and typed config per environment.
- **File uploads.** Multipart parsing, size limits, streaming to disk.
- **Validation.** Typed form schemas with per-field errors returned to the form.
- **Error handling.** Custom 404 and 500 pages, error boundaries in components, a dev error page with source lines.

### Operations

- Structured logging, metrics and tracing (OpenTelemetry).
- Health checks, graceful shutdown, zero-downtime restart.
- Linux and Docker builds, and a deploy guide. Windows was asked about earlier.
- Rate limiting, CORS, security headers, CSP nonces.

### Platform

- WebSockets.
- Background jobs and scheduled tasks.
- Postgres support and a query builder.
- i18n.
- SEO helpers: sitemap and robots.txt.
- Route and integration test helpers that run a route in-process.

### Tooling and maturity

- **`.gshtml` language server.** Proxy to `goose lsp` through source maps from gweb's compiler, with HTML and CSS services for the markup. First version: diagnostics only, mapped to `.gshtml` lines. Add position tracking to the template compiler early, while it is small.
- A documentation site and a tutorial.
- A stability and semver policy for v1.0.
- A way for packages to ship components and routes.

## CMS architecture (separate repo, likely `goose-cms`)

Goal: a CMS built on gweb, structured like Kentico, with inspiration from Storyblok, and not headless. Pages render on the server. The user enjoys Kentico as both an editor and a developer, and wants its page builder with predefined code widgets. This revises the recommendation in `CMS-STUDY.md` (Option A): add a database-first content tree, and move the widget page builder from Phase 3 into the core. An Opus 5.5 medium architect writes the design before any builder starts.

**Direction (user, 2026-11-12):**
- **Content tree in the database.** Tree nodes hold parent, order, slug, page type and published state. One `[[...path]]` catch-all route resolves every URL through a path index. Editors add, move and reorder pages in the admin with no rebuild. Navigation and menus are queried from the tree.
- **Page types in code.** Goose structs with typed fields. A node records its type, and the type picks its template.
- **Page builder with code widgets.** Developers write widgets (`.gshtml` or template partials) with typed properties declared as structs. Editors place widgets into zones, inside sections or layouts in the style of Kentico, and fill in the properties through a generated form. Only widget placement and property values live in the database.
- **Rebuilds** are needed only for new page types, widgets or templates, which is developer work.

**What stays in code:** page types, widgets, sections, templates and the admin UI.

**New work:**
- Tree operations: move, reorder and copy (rewriting child paths), and redirects when a slug changes.
- Storage of page builder data: JSON per page or rows per widget.
- Read path: path lookup, node load, then template and widget render, in one or two queries. A published-page cache matters early.
- Drafts and published versions for each node, and preview.
- Admin: the tree editor and the page builder, with drag and drop and possibly live preview.

**gweb prerequisites:**
- Built in v0.2.0: CSRF, catch-all routes, the SQLite writer, forms and cookies.
- Missing: sessions and login (see "Auth and signed sessions" above), rendering a widget by name chosen at run time from data (today a template names its components at build time), markdown rendering and media uploads.

**Questions for the architect:** how widgets declare properties and how admin forms are generated (reflection?), the widget data storage format, the section, zone and layout model, the page builder editor (drag and drop, live preview), the cache and its invalidation, and the repo layout.
