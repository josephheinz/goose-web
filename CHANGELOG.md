# Changelog

## Unreleased

- Reactive components: `@prop`, `@state`, `@computed`, `@watch`. gweb finds which markup reads which names and, after a handler, updates only those text nodes, attribute lists and `{#if}`/`{#for}` blocks. Markup names state directly (`{count}`). A throwing handler leaves the page unchanged. `struct State` components still work.
- Pages call reactive components with named props: `@Counter(start: 3, label: p.name)`.
- Async handlers: `await http::get` and `http::post` with typed replies. A failure restores what the handler wrote and raises `gw:error`.
- Lifecycle: `@mount`, `@unmount`, `@every(ms)`.
- Events: `dblclick`, `keydown`, `keyup`, `focus`, `blur`, and modifiers `on:keydown.enter.prevent`, `stop`, `300ms`.
- Nested components with props (`@Card(title: x, key: id)`) and child events (`@event fn`, `on:change="picked"`).
- Shared stores: `stores/Name.gshtml` and `@use`, optionally kept in `localStorage`.
- Client navigation: `<body gw-boost>`.
- Transitions: `gw-enter` and `gw-leave`.
- Server push, client half: `gw-sse="/events"`, and `web::sse_event`, `web::sse_fragment`, `web::sse_store`. The streaming server half is not in this release.
- Warnings: `gen`, `build`, `start` and `test` take `--strict` and `--diagnostics json`. New codes: `unkeyed-for`, `unknown-attribute`, `unknown-event`, `child-key`, `prop-keyword`, `state-keyword`, `computed-keyword`, `computed-no-state`, `watch-no-state`, `state-unused`. `gweb dev` shows warnings in a corner box.
- Runtime split: `gwi.js` is the 4 KB core. Fragments and each other feature are optional modules (`gwf`, `gwh`, `gwl`, `gwm`, `gwc`, `gwn`, `gws`, `gwt`, `gwe`), served only to sites that use them. Fragment pages now load `gwf.js` and `gwi.js`.
- Changed: a component root with a text part gets `<!--g-->` markers in its HTML.

## v0.2.1

- Fix: `gweb test` no longer deletes `.gooseweb/`; it generates into `.gooseweb.test/`. Add `.gooseweb.test/` to `.gitignore`.

Pins goose-net v0.2.1 and goose-sqlite v0.2.1.

## v0.2.0

- Breaking: CSRF tokens are on by default. Every page `fn POST` and every `route.goose` `POST`, `PUT`, `PATCH` or `DELETE` answers 403 until its forms add `@web::csrf_field(ctx)`, or the route declares `const CSRF = false;`. `Sec-Fetch-Site: same-site` is refused as well as `cross-site`, and `web::cross_site` is removed.
- Catch-all routes: a `[...name]` folder matches one or more trailing segments and `[[...name]]` zero or more. `web::param` returns the raw tail, and `web::path_decode` decodes it. A tail over 1,024 bytes, or with an empty or dot segment, `%2F`, `\` or a control byte, gets a 404.
- Behaviour change: `public/` files are now tried before every route for GET and HEAD. A public file that an `[id]` route at the same depth used to shadow is now served. A route that has the same URL as a public file is still a build error.
- A route folder deeper than 16 folders is now a build error; it was silently never matched.
- Keyed morph: `gw-key` keeps element identity and focus when list items move, appear or disappear.
- SQLite writes: the owner-thread writer pattern, documented, with the shop's `/db/todos` demo; needs goose-sqlite v0.2.0.

Pins goose-net v0.2.0 and goose-sqlite v0.2.0.

## v0.1.1

The repos moved from `jheinz-bzs` to `josephheinz`. `gweb` now pins `josephheinz/goose-*@v0.1.1`.

Pins goose-net v0.1.1 and goose-sqlite v0.1.1.

## v0.1.0

First tagged release: file-based routes, templates, components, fragments, cookies, owner state, and the `gweb` command line.

Pins goose-net v0.1.0 and goose-sqlite v0.1.0.
