<!-- Produced by goose-architect on claude-opus-5-5 (medium) -->
# Addendum 15: delivery and transport (goose-web v0.3, goose-net v0.3)

## Summary

- **TLS, HTTP/2 and compression go to a reverse proxy.** goose-web keeps speaking HTTP/1.1 on loopback. `docs/DEPLOY-PROXY.md` gives Caddy (recommended) and nginx configs. goose-web adds only what a proxy cannot do well: gzip variants of static files made at build time.
- **Static asset pipeline.** Every `public/` file and every `/_gw/` script gets a second URL with a content hash, `/css/site.3f9a1c2b.css`, served with `Cache-Control: public, max-age=31536000, immutable`. The plain URL stays, with today's revalidating headers. `@asset("/css/site.css")` in a template writes the hashed URL at build time and fails the build for a missing file. `gweb build` minifies `.css`. JavaScript is not minified by gweb.
- **Images and metadata.** `@image("/img/logo.png", "Logo")` writes an `<img>` with the hashed URL, `width`, `height` read from the file at build time, `loading="lazy"`, `decoding="async"`, and a `srcset` when a `name@2x.ext` file exists. `@meta()` in a layout writes description, canonical, robots and Open Graph tags from `ctx.meta`.
- **SEO.** An `app/sitemap.goose` turns on a generated `/sitemap.xml` (every literal page plus the entries the file adds) and, unless `public/robots.txt` exists, a `/robots.txt` that names it.
- **Caching.** `const REVALIDATE = 60;` in a `page.goose` caches the rendered page per worker for 60 seconds, with an ETag and 304. `gweb export` writes literal pages, `fn static_paths()` pages and `public/` to a folder for a static host.
- **Streaming.** `web::stream_begin` sends a chunked response from a route while the handler writes it. It holds the worker, so it is for seconds, not minutes.
- **Long-lived connections.** A new goose-net `net::Hub` owns detached connections on one thread: chunked streams (the transport for SSE) and WebSockets. Handlers call `web::subscribe` or `web::websocket`; any worker calls `web::publish(ctx, topic, data)`. An optional `app/socket.goose` receives WebSocket messages.

## What I read, and the evidence

Read: `docs/BACKLOG.md`, `ARCHITECTURE.md`, `DESIGN.md` (sections 8 to 10), Addenda 1 to 11 (8 and 11 in full), `static.goose`, `web.goose`, `template.goose`, `cli/gweb.goose` (scan, `content_type`, `etag_of`, `scan_public_dir`, `gen_static`, `gen_dispatch`, `gen_page_fn`, `template_call`, `compile_template`, `gen_main`, `gen_runtime`, `gen_components`), the end of `cli/component.goose`, `client/build.sh`, goose-net `net.goose`, `http.goose`, `src/loop.c`, `src/net.c` signatures, `test/test_net.goose`, and the three `.build` files. No sibling addendum (12 reactivity, 13 auth-security, 16 operations, 17 platform) existed when I wrote this.

Evidence that shapes the design:
- `net::Loop` (`src/loop.c`) hands out one framed request at a time and keeps the connection. Responses always carry `Content-Length`, written by a blocking `send` under a 5 s send timeout. A worker that blocks blocks every connection on its loop. There is no way to take a connection out of a loop, and no chunked or 1xx response.
- `run_worker` owns the socket. `D` (the dispatcher) sees only `req`, `ctx` and `res`. `Ctx` "holds no references or slices", and `thread_fn` workers "may not reach a growable global" (`http.goose`). So state shared across threads must live in C, behind a handle.
- `c_libs = ["sqlite3"]` in `sqlite.build` shows a package can link a system library, so gweb can link zlib. macOS ships no OpenSSL headers, so in-process TLS would mean vendoring a TLS library.
- Statics are embedded with `embed_file` and found by `match p.len` then compare (`gen_static`). ETags are FNV-1a 64 (`etag_of`), `Cache-Control: public, max-age=0, must-revalidate` (`send_static`). DESIGN.md 8 rejected long `max-age` for want of fingerprinted names and left precompression for v2.
- Component pages load `/_gw/Name.js`, which imports `./gwi.js` (`component.goose` lines near 2661 and 2675). Layouts and pages load `/_gw/gwi.js` through `GW_SCRIPT` (`gweb.goose`).
- `@slot()` shows that a lowercase `@name()` is a built-in, checked in `template_call`. Components are `[A-Z]...`, so `@asset`, `@image` and `@meta` cannot clash with them.
- `fn state::ask` is defined by the generated `main.goose` inside a namespace the app declared. So main can define `fn web::asset_url` the same way.

Not verified, because no `goose` compiler is on this machine: everything that needs a Goose build. The C cores of the hub, the WebSocket codec and gzip are designed to compile without `goose.h`, so their tests run with `cc`.

## 1. TLS, HTTP/2 and compression: a reverse proxy

**Choice.** goose-web does not terminate TLS or speak HTTP/2. Production runs behind Caddy or nginx on the same host, with the server on `--host 127.0.0.1`. New `docs/DEPLOY-PROXY.md`:

- **Caddy (recommended):** automatic certificates, HTTP/2 and HTTP/3, WebSocket and streaming with no extra lines.
  ```
  example.com {
      encode zstd gzip
      reverse_proxy 127.0.0.1:3000
  }
  ```
- **nginx:** `listen 443 ssl http2`, certificates from certbot, `proxy_http_version 1.1`, `proxy_set_header Host $host`, `X-Forwarded-Proto $scheme`, the `Upgrade`/`Connection` map for WebSockets, `proxy_buffering off` (or rely on the `X-Accel-Buffering: no` the hub's streams send), `proxy_read_timeout 1h` for long-lived locations, and `gzip on` with `gzip_types` for HTML and JSON.
- Both: the proxy passes an existing `Content-Encoding` through, so the build-time gzip variants are served as they are and not compressed twice.
- Notes: set `secure` on cookies (README already says so); CSRF already reads `X-Forwarded-Proto`. HSTS and trusting forwarded headers belong to Addendum 13.

**Why.**
- TLS needs a library (OpenSSL is not on macOS by default) and certificate renewal (ACME). Caddy does both and is updated by people who do only that.
- HTTP/2 needs HPACK, stream multiplexing and flow control. It does not fit a loop that serves one framed request at a time and writes with a blocking send. Browsers use HTTP/2 only over TLS, so it would come with TLS anyway.
- Between proxy and server on loopback, HTTP/1.1 keep-alive is as fast as h2c.
- Dynamic compression costs CPU per response and the proxy already does it, with zstd and brotli. Static files are the exception: compressing them once at build time is free at run time, and it helps when no proxy compresses.

**Rejected.**
- In-process TLS with a vendored library (BearSSL, mbedTLS): a large C dependency, certificate reload, and no ACME.
- In-process HTTP/2: a second server core.
- Run-time gzip of HTML and JSON (`--compress`): duplicates the proxy and puts zlib in every server binary. Revisit if users deploy without a proxy (open question 1).
- Brotli variants: no system library on macOS. The proxy can do it.

## 2. Static asset pipeline

### 2.1 Hashed URLs and cache headers

**Choice.**
- `etag_of` stays. The hash text is its first 8 hex digits. The hashed URL puts it before the last extension: `/css/site.css` becomes `/css/site.3f9a1c2b.css`; `/LICENSE` becomes `/LICENSE.3f9a1c2b`. A dot in a folder name does not count.
- Each static file is served at both URLs from the same embedded bytes.
  - Plain URL: today's headers.
  - Hashed URL: `Cache-Control: public, max-age=31536000, immutable`, plus the same `ETag`.
- `/_gw/` gets the same treatment, and pages refer to the hashed names: `GW_SCRIPT` writes `/_gw/gwi.<h>.js`; a component's server render writes `/_gw/Name.<h>.js`; and a component's JS imports `./gwi.<h>.js`. The runtime is hashed first, so a component's hash covers the runtime name it imports.
- Build errors: a hashed URL equal to another static or route URL, with the message `this file's hashed URL <u> is taken by <other>`.
- `send_static` gains `immutable: bool` and `gz: i64` (section 2.2): `send_static(req, res, index, gz, content_type, etag, immutable)`.

**Why.** Long caching is safe only for names that change with content. Keeping the plain URL means links in CSS (`url(/img/x.png)`), outside sites and old HTML keep working. One embedded copy serves both, so the binary does not grow.

**Rejected.**
- A manifest JSON read at run time: one more file and a lookup at run time for no gain.
- Rewriting `url(...)` inside CSS to hashed names: changes CSS bytes and so the hash, in dependency order. Plain URLs inside CSS still revalidate cheaply with 304.
- Query-string cache busting (`?v=hash`): some proxies and CDNs do not cache query URLs.
- Hashes in folder names (`/_assets/3f9a/site.css`): breaks relative URLs in CSS.

### 2.2 Build-time gzip

**Choice.**
- For files with a text type (`text/*`, `application/json`, `application/xml`, `image/svg+xml`, `application/wasm`) of at least 1,024 bytes, gweb gzips at level 9 with zlib and no file name or time stamp, so builds are reproducible. It keeps the result only when it is at most 90% of the original.
- The variant is written to `<out>/_gz/<index>.gz` and embedded as another `static_bytes` index.
- `send_static` with `gz >= 0`:
  - always adds `Vary: Accept-Encoding`;
  - when `http::accepts(req, "gzip")` holds, it returns the gz index, adds `Content-Encoding: gzip` and uses the ETag `"<16 hex>-gz"`.
  - If-None-Match is checked against the ETag of the representation it would send.
- `http::accepts(req, coding) -> bool` is new in goose-net. It parses `Accept-Encoding` as a comma list of tokens with optional `;q=`. A token with `q=0` is refused, and `*` matches when no explicit entry exists.
- gweb links zlib: `cli/gweb.build` gets `c_libs = ["z"]`. `cli/gzip.c` holds `gweb_gzip(in, out&)` and has no `goose.h` dependency in its core function, so `cli/gzip_test.c` runs with `cc ... -lz`. The server never links zlib.

### 2.3 CSS minification

**Choice.** `gweb build` and `gweb start` minify `public/**/*.css`; `gweb dev` does not; `--no-minify` turns it off. The minifier is conservative. It keeps strings (`"..."`, `'...'`) and `url(...)` contents byte for byte. It removes `/* */` comments, except `/*! ... */`. It collapses whitespace runs to one space and drops the space next to `{ } ; : , > ~ +`. It never touches a `+` or `-` inside a `calc(`, and it keeps the space before `(` and after `and`. If the output fails a brace-balance check, gweb uses the original and keeps going. Hashes and ETags are of the bytes served.

**Rejected.** A JavaScript minifier in gweb: a correct one needs a JS parser (ASI, regex literals, template strings). Generated component JS is already compact in production, and `gwi.min.js` comes from esbuild. Users who want minified JS run esbuild before `gweb build` and keep the output in `public/`.

### 2.4 `@asset()` and `web::asset_url`

**Choice.**
- `@asset("/css/site.css")` in a `page.html` or `layout.html` takes a string literal naming a static URL. It compiles to `out.append("/css/site.3f9a1c2b.css");`. Errors:
  - `@asset() takes one string literal, as in @asset("/css/site.css")`
  - `no public file at /x.css (looked for public/x.css)`
- For URLs known only at run time, main.goose defines `fn web::asset_url(path: const u8[:]) -> const u8[:]`: the hashed URL for a known plain URL, or else `path` unchanged. It is generated with the same `match len` shape as `static_file`.
- Components: not in v1, because both the Goose render and the JS render would need the literal, and `component.goose` is being reshaped by Addendum 12. Open question 4.

## 3. Images and metadata

### 3.1 `@image(path, alt[, attrs])`

**Choice.**
- `path` is a string literal naming a static URL. `alt` is any Goose expression and is escaped (`""` for decorative images). `attrs` is an optional string literal of extra attributes, copied as written.
- The output is `<img src="HASHED" width="W" height="H" alt="..." loading="lazy" decoding="async"[ srcset="HASHED 1x, HASHED2 2x"] ATTRS>`.
- `loading` and `decoding` are left out when `attrs` names them.
- `srcset` is written when `name@2x.ext` exists beside the file.
- gweb reads the intrinsic size at build time:
  - PNG: IHDR.
  - GIF: the logical screen.
  - JPEG: the first SOFn marker, skipping C4, C8 and CC.
  - WebP: VP8, VP8L and VP8X.
  - SVG: `width` and `height` attributes in plain px or unitless numbers, or else the `viewBox`.
- When gweb cannot read a size it writes no `width` or `height`. That is not an error.
- Error: `@image() needs a string literal path and an alt text, as in @image("/img/a.png", "A")`.

**Why.** Width and height prevent layout shift, which is the main thing Next's `<Image>` gives. Lazy loading and immutable caching come free with section 2.

**Rejected.** Resizing and format conversion (Next's image optimizer) at run time or build time. It needs an image decoder (libvips, ImageIO) per platform. Users run `sharp` or `vips` once and commit the variants. The `@2x` convention covers high-DPI screens.

### 3.2 `ctx.meta` and `@meta()`

**Choice.**
- `web::Meta { description: u8[..320], canonical: u8[..512], image: u8[..512], robots: u8[..64] }` becomes a field `meta` of `Ctx`, with defaults `""`. `ctx.title` stays where it is.
- Setters cut at a UTF-8 boundary to fit: `web::meta_description(ctx, s)`, `web::meta_canonical(ctx, url)`, `web::meta_image(ctx, url)` and `web::meta_robots(ctx, s)`.
- `@meta()` is allowed only in `layout.html` (error `@meta() is for layout.html only`). It writes only non-empty tags, each escaped:
  - `<meta name="description">`
  - `<link rel="canonical">`
  - `<meta name="robots">`
  - `og:title` from `ctx.title`, `og:description`, `og:url` from canonical, and `og:image`
  - `<meta name="twitter:card" content="summary_large_image">` when an image is set
- A canonical or image URL that starts with `/` is made absolute with `web::site_url` (section 4).
- `@meta()` does not write `<title>`; layouts already do.

**Why.** It is one call in the layout and plain setters in `load`, which matches how `ctx.title` works today. It adds 1.4 KB to `Ctx`, all fixed size, against about 3.5 KB today.

**Rejected.** A `fn metadata(props) -> Meta` export in `page.goose`, which is Next-like but needs a second generated call and gives no more than setters in `load`.

## 4. Sitemap and robots.txt

**Choice.**
- `app/sitemap.goose` (namespace added by gweb as for other files) turns on generated GET and HEAD routes at `/sitemap.xml` and, when `public/robots.txt` does not exist, `/robots.txt`. It may define `fn entries(req: const http::Request&, ctx: web::Ctx&, s: web::Sitemap&)`. A file with no function still turns the routes on.
- `/sitemap.xml` lists every page with no dynamic segment, except a page whose `page.goose` has `const SITEMAP = false;`. Then it lists the entries added by `web::sitemap_add(s, path, lastmod = "")`. `path` starts with `/`, and `lastmod` is `YYYY-MM-DD` or `""`.
- Output is the 0.9 urlset, escaped. The cap is 50,000 URLs; later adds return false.
- `/robots.txt` is `User-agent: *\nAllow: /\nSitemap: <base>/sitemap.xml\n`. A site that wants other rules writes `public/robots.txt`, which wins and is served as a static file.
- `web::site_url(req, out&)` appends the base URL. It is the `SITE_URL` environment variable without a trailing `/`, or else `http` or `https` (from `X-Forwarded-Proto`) plus `://` plus the `Host` header. The README tells production sites to set `SITE_URL`, because `Host` comes from the client.
- Both routes send `Cache-Control: public, max-age=3600`.
- Build error: `app/sitemap.goose` beside `public/sitemap.xml`.

**Why.** It is opt-in, so no existing site changes. Literal pages come for free, and dynamic pages come from data, the way Next's `sitemap.ts` works.

**Rejected.** Sitemap index files past 50,000 URLs (v2), and a generated `robots.txt` for sites without a sitemap (it would change existing sites).

## 5. Page cache and static export

### 5.1 `const REVALIDATE = N;`

**Choice.**
- A `page.goose` line `const REVALIDATE = N;` (N > 0, in seconds) caches the page's GET response per worker. It is detected like `const CSRF` (`csrf_const`). A malformed value is a build error. So is a cached page that starts a CSRF token (`starts_token`): `a page with REVALIDATE cannot use a CSRF token; its HTML would be shared by every visitor`.
- Generated `page_N`, after `middleware_before`, for GET and HEAD without a `GW-Fragment` header:
  - `if web::cache_serve(req, ctx, res) { <middleware_after>; return; }`
  - after the reply: `web::cache_store(req, ctx, res, N);`
  - POST and fragment requests skip both.
- `cache_store` stores only when `ctx.outcome == Continue`, the status is 200, `ctx.set_cookies` is empty and the body is at most 1 MB. It stores the content type, `res.headers`, the body and its ETag. Every cached reply gets `ETag` (FNV-1a 64) and `Cache-Control: public, max-age=0, must-revalidate`. If-None-Match gives 304.
- The key is `req.target` (path and query), at most 1,024 bytes; a longer one is not cached.
- Storage: new goose-web `src/cache.c`, thread-local, so it needs no lock. Its limits are 512 entries and 16 MB per worker. When full, the entry that expires soonest is evicted. Its C core has no `goose.h` dependency and has a `cc` test.
- The dev script is appended after dispatch, so the cache never stores it.

**Why.** Rendering is microseconds, but `load` may query a database. A per-worker cache needs no locks and no owner-thread round trip. The cost is up to `workers` renders per expiry.

**Rejected.**
- A shared cache on the owner thread: a socketpair round trip on every hit.
- Varying by cookie: a page that reads cookies must not be cached, and that is documented. Only a page that sets cookies is caught at run time.
- On-demand invalidation (`revalidatePath`): v2, together with Addendum 17's jobs.

### 5.2 `gweb export`

**Choice.**
- `gweb export [-o DIR]` (default `out/`) runs a build, then `.gooseweb/server --export DIR`. `--export DIR` is a new `Config` flag. When it is set, the generated `main` exports and exits; it starts no workers and opens no socket.
- It writes:
  - Every page with no dynamic segment, plus each path returned by `fn static_paths() -> u8[..1024][>..]` in a `page.goose` (dynamic pages without that function are skipped and listed). Each is rendered in process through `dispatch` with a synthetic `GET <path> HTTP/1.1\r\nHost: localhost\r\n\r\n`, and written as `DIR/index.html` for `/`, and `DIR/<path>.html` otherwise.
  - Every static file at its plain and hashed URL.
  - `sitemap.xml` and `robots.txt` when they exist. Set `SITE_URL` for the export.
- A non-200 reply is an error; the export goes on and exits 1. The last line is `gweb: exported N pages and M files to DIR`.
- The README notes that fragments, forms, routes and component handlers that call routes need a server. Static components work.

**Why.** Static hosts (GitHub Pages, Cloudflare Pages, Netlify) serve `/about` from `about.html`. Rendering in process needs no port and no HTTP client in gweb.

## 6. Streaming responses

**Choice.**
- goose-net `http`:
  - `begin_chunked(conn, res, head_only, keep_alive) -> bool` sends the head with `Transfer-Encoding: chunked`.
  - `format_chunk(out&, data)`, `send_chunk(conn, data) -> bool` and `end_chunked(conn) -> bool` handle the chunks. An empty `data` sends nothing, because a zero chunk would end the body.
  - For an HTTP/1.0 request, `begin_chunked` sends no length and `Connection: close`, and the chunk calls write raw bytes. `Stream` remembers which mode it is in.
- goose-web: `Ctx` gains `conn_fd: i32 = -1` (set by `run_worker`), and `streamed: bool = false`. New file `stream.goose` (namespace `web`):
  - `stream_begin(req, ctx, res) -> Stream` applies queued cookies, sends the head, and sets `ctx.streamed`.
  - `write(s: Stream&, data) -> bool` sends one chunk.
  - `end(s: Stream&) -> bool` ends the body.
  - `run_worker` sends nothing for a streamed request. It keeps the connection only when the stream was chunked, ended and keep-alive was asked for.
- HEAD gets the head only, and `write` then returns true without sending.
- A stream holds its worker until it ends. The README says so: use it for exports and downloads, and use `subscribe` (section 7) for anything that waits on events.

**Rejected.** Streaming page HTML before `load` finishes (Next's Suspense shell). The status, redirect and cookies are decided in `load`, and the page renders in microseconds once `load` is done, so there is little to gain.

## 7. Long-lived connections: `net::Hub`, SSE transport and WebSockets

### 7.1 goose-net

**Choice.**
- `net::Loop.detach(l, conn, rest: u8[>..]&)` removes the connection from the loop without closing it. It appends any bytes buffered after the current request (a WebSocket client may send its first frame right away). C: `gnet_loop_detach`.
- `http::Status.SwitchingProtocols` (101). Also `http::send_head(conn, res, connection: const u8[:]) -> bool`, which writes the status line, `res.headers` and `Connection: <connection>` with no body headers, for the 101.
- `net::Hub`, in `hub.goose` (import `net.hub`, namespace `net`), backed by `src/hub_core.c` and `src/hub_core.h` (plain C, no `goose.h`) and `src/hub.c` (the glue):

```goose
struct Hub { handle: u64 }
enum HubKind { Stream, WebSocket }
enum HubEvent { Open, Text, Binary, Close, Failed }

fn hub(max_conns: i64 = 10000, max_message: i64 = 65536, out_limit: i64 = 1048576, ping_ms: i64 = 30000) -> Hub
// Any thread. The hub owns fd from now on. 0 when the hub is full (the fd is closed).
fn add(h: Hub, conn: Socket, kind: HubKind, topic: const u8[:], pending: const u8[:], heartbeat: const u8[:] = "") -> u64
fn send(h: Hub, id: u64, data: const u8[:], binary: bool = false) -> bool     // any thread; false when the queue is over its limit
fn publish(h: Hub, topic: const u8[:], data: const u8[:], binary: bool = false) -> bool   // any thread
fn close(h: Hub, id: u64)                                                     // any thread
fn count(h: Hub, topic: const u8[:]) -> i64                                   // any thread; "" counts all
// Hub thread only: runs the poll loop until an event. out gets a message; topic gets the connection's topic.
fn next(h: Hub, out: u8[>..]&, topic: u8[>..]&) -> u64, HubEvent
```

- Threads: one mutex guards a command queue (add, send, publish, close) and the connection table. A wake pipe interrupts the hub's `poll`. Only the thread in `next` does I/O, and every socket is non-blocking. The command queue is capped at 64 MB of payload, and `send` and `publish` return false past it.
- Per connection:
  - an output buffer up to `out_limit`; past it the connection is closed (slow consumer);
  - one topic of at most 64 bytes, matched exactly;
  - a u64 id that is never reused.
- Stream kind: each `send` or `publish` is one HTTP chunk. Every `ping_ms` the hub sends `heartbeat` as a chunk when it is non-empty. Input is read and dropped; EOF or an error closes the connection. Closing sends `0\r\n\r\n` first.
- WebSocket kind (RFC 6455) in `hub_core.c`:
  - Client frames must be masked; an unmasked frame closes with 1002.
  - Continuation frames are joined up to `max_message`; past it, close 1009.
  - Text must be valid UTF-8, or close 1007.
  - Ping is answered with pong.
  - A close frame is echoed, and then the socket closes.
  - The hub sends a ping every `ping_ms` and closes a connection that has sent nothing for 2.5 × `ping_ms`.
  - Server frames are unmasked, text or binary.
  - No extensions: `permessage-deflate` is not offered.
- `ws_accept_key(key, out&)`: SHA-1 and base64, in C (`hub_core.c`), and exposed to Goose as `http::websocket_accept(key) -> u8[..28]`.
- `Open` is reported when the hub thread takes the connection in, and `Close` once for every connection that was opened, whatever the reason.
- `test/hub_core_test.c` covers the RFC 6455 accept-key example, frame encode and decode (masked, 7, 16 and 64-bit lengths, fragmentation, control frames in the middle of a message, the close codes), UTF-8 checks and the chunk format. It runs over a `socketpair` with a hub on a pthread: add, publish, the slow-consumer close and wake-ups. Run it with `cc -pthread`.

### 7.2 goose-web

**Choice.**
- `Config` gains `hub: u64 = 0`. `Ctx` gains `hub: u64`, `detach: Detach = Detach.None` (`enum Detach { None, Stream, WebSocket }`), `topic: u8[..64]` and `heartbeat: u8[..64]`. `new_ctx` copies `cfg.hub`.
- New file `push.goose` (namespace `web`):
  - `subscribe(req, ctx, res, topic, heartbeat = "") -> bool`. Content type is the caller's (SSE sets `text/event-stream`). It adds `Cache-Control: no-store` and `X-Accel-Buffering: no`. It answers 503 `{"error":"no hub"}` when there is no hub, and 400 when the topic is over 64 bytes or HEAD is used.
  - `websocket(req, ctx, res, topic, allow_origin = "") -> bool` checks that the request is a GET with `Upgrade: websocket`, a `Connection` that contains `upgrade` (case-insensitive token), `Sec-WebSocket-Version: 13` and a key that decodes to 16 bytes.
    - On failure: 426 with `Sec-WebSocket-Version: 13`, or 400.
    - Origin: when `Origin` is present, its host and port must equal `Host` unless they equal `allow_origin`. Otherwise 403 `cross-origin WebSocket refused`. This blocks cross-site WebSocket hijacking with cookie auth.
    - On success: status 101, `Upgrade: websocket` and `Sec-WebSocket-Accept`.
  - `publish(ctx, topic, data, binary = false) -> bool`, `send(ctx, id, data, binary = false) -> bool`, `close_socket(ctx, id)` and `subscribers(ctx, topic) -> i64` wrap the hub.
- `run_worker`, after `D` and `apply_cookies`:
  - `Detach.Stream`: `http::begin_chunked`, then `lp.detach`, then `net::add(hub, conn, Stream, topic, rest, heartbeat)`.
  - `Detach.WebSocket`: `http::send_head(conn, res, "Upgrade")`, then `detach`, then `add(... WebSocket ...)`.
  - The connection is not closed, and it is not logged as a normal reply.
- Generated `main`:
  - The hub is created only when some file under `app/` or `lib/` mentions `web::subscribe(` or `web::websocket(`, or `app/socket.goose` exists.
  - `main` creates it with `net::hub()`, stores it in `cfg.hub`, and spawns `thread_fn hub_thread(cfg, owner_fd)`.
  - That thread loops on `net::next` and calls `socket::open(ctx, id, topic)`, `socket::message(ctx, id, topic, data, binary)` and `socket::close(ctx, id, topic)` when `app/socket.goose` defines them. Messages are dropped otherwise.
  - With `app/state.goose`, the owner gets one more channel (`workers + 1`) for the hub thread, so handlers can `state::ask`.
- Coordination with Addendum 12 (reactivity): it owns SSE, meaning the `gw-sse` client, the event format and any page-level API. Its server side is `web::subscribe(req, ctx, res, topic, ": ping\n\n")` with `text/event-stream`, plus `web::publish`. If 12 needs another transport primitive, it asks here and does not edit `run_worker` itself.
- Coordination with Addendum 16 (operations): on graceful shutdown, call `net::close` for every hub connection, or add `net::hub_shutdown`. The hub never counts toward "in-flight requests".

**Why.**
- One hub thread per process scales to thousands of idle connections with one poll. Workers stay free.
- It mirrors the owner-thread pattern users already know: plain fds and handles, no locks in Goose.
- WebSockets and SSE share one connection table, one heartbeat timer and one publish fan-out.

**Rejected.**
- A thread per long-lived connection: thousands of threads.
- Keeping long-lived connections inside each worker's `Loop`: the loop is built around framed requests and blocking sends, and a publish would have to reach every worker.
- Multiple topics per connection: v1 keeps one; a client opens one socket per topic, or the app fans out with `send`.
- `permessage-deflate`: a zlib dependency in every server and a known memory cost per connection.
- An `epoll`/`kqueue` backend: `poll` is enough to about 10,000 connections and matches `loop.c`.

## 8. Files and shared edit regions

| Repo | File | Steps | Shared with |
|---|---|---|---|
| goose-net | `http.goose` | N1, N3 | none known |
| goose-net | `net.goose`, `src/loop.c` (`detach`) | N1 | none known |
| goose-net | `hub.goose`, `src/hub_core.[ch]`, `src/hub.c`, `test/hub_core_test.c`, `net.build`, `examples/ws_echo.goose` | N2, N3 | new |
| goose-web | `cli/gweb.goose`: `etag_of` callers, `Static`, `scan_public_dir`, `gen_static`, `template_call`, `GW_SCRIPT`, `gen_runtime`, `gen_components`, `gen_page_fn`, `gen_main`, the command table | W1 to W6 | every web architect touches `gen_main`/`gen_page_fn`: rebase by hand |
| goose-web | `cli/component.goose`: the two `/_gw/` strings only | W1 | Addendum 12, heavy edits: W1 changes only those lines |
| goose-web | `cli/gzip.c`, `cli/gzip_test.c`, `cli/gweb.build` | W2 | new |
| goose-web | `static.goose` | W1, W2 | none known |
| goose-web | `web.goose`: `Ctx`, `Config`, `new_ctx`, `config_from_args`, `run_worker` | W3, W5, W6 | 13 and 16 edit `Config`, `Ctx` and `run_worker` |
| goose-web | `meta.goose`, `sitemap.goose`, `stream.goose`, `push.goose`, `src/cache.c`, `web.build` | W3 to W6 | new |
| goose-web | `README.md`, `CHANGELOG.md`, `docs/ARCHITECTURE.md`, `docs/DEPLOY-PROXY.md` | W7 | everyone: append sections |

## 9. Build plan

Two lanes run in parallel: **N** (goose-net worktree `/Users/josephheinz/Documents/goose/goose-net/.worktrees/delivery`, branch `arch/delivery`) and **W** (goose-web worktree `/Users/josephheinz/Documents/goose/goose-web/.worktrees/delivery`, branch `arch/delivery`). Within a lane, steps run in order. W6 starts after N3. One commit per step. Commit locally, never push.

**Toolchain.** Check `$GOOSE`, then `goose` on `PATH`. If neither exists, write the code and the tests, run everything that runs without Goose (`cc` tests, `sh -n` on scripts, `node` checks), and say in the commit body which tests did not run. The goose-web test sites import `net` from `../../goose-net`. From a worktree that path does not exist, so with a compiler, point it at the goose-net worktree.

Code style: why-comments only. No comment restates code or names this document. Error messages are exactly as written here.

**N1. HTTP primitives** (`http.goose`, `net.goose`, `src/loop.c`, `test/test_net.goose`)
- `Status.SwitchingProtocols` (101, "Switching Protocols") in `code`, `reason`, `status_from_code`.
- `send_head`, `begin_chunked`, `format_chunk`, `send_chunk`, `end_chunked` (section 6).
- `accepts(req, coding)` (section 2.2).
- `Loop.detach` and `gnet_loop_detach` (section 7.1).
- Tests: the chunk format; `accepts` with `gzip`, `gzip;q=0`, `*`, `br, gzip;q=0.5`, absent header, `GZIP` (case-insensitive); a served chunked reply that the goose-net client decodes; a detached connection that a test thread then writes to, with the bytes a client sent after the request arriving in `rest`.
- Done: `test_net` passes at 142 checks or more, or the code is written and marked untested.

**N2. Hub core in C** (`src/hub_core.h`, `src/hub_core.c`, `test/hub_core_test.c`)
- The connection table, command queue, wake pipe, the poll step, Stream and WebSocket kinds, SHA-1, base64, the frame codec and UTF-8 checks (section 7.1). The C API uses plain types (`const uint8_t*`, `size_t`); the event comes back in a caller-owned growable buffer struct defined in `hub_core.h`.
- Tests: every case listed in section 7.1. `cc -std=c11 -Wall -Wextra -pthread src/hub_core.c test/hub_core_test.c -o /tmp/hub_test && /tmp/hub_test` prints `N of N checks passed`.
- Done: it builds with no warnings on macOS and the test passes. This step must be tested.

**N3. Hub in Goose** (`src/hub.c`, `hub.goose`, `net.build`, `http.goose`, `test/test_net.goose`, `examples/ws_echo.goose`, `README.md`, `CHANGELOG.md`)
- Glue `gnet_hub_*` externs over `hub_core`; `net.build` lists `src/hub_core.c` and `src/hub.c`; the `hub.goose` API exactly as in section 7.1; `http::websocket_accept`.
- `examples/ws_echo.goose`: an `http::serve`-like loop that upgrades `/ws` and echoes through a hub thread.
- Tests in `test_net`: a WebSocket handshake by raw socket, then a masked text frame, an echo, publish to two clients, and a close.
- README: `net::Hub` and the chunked functions. CHANGELOG: `## Unreleased`.
- Done: compiles and passes with Goose, or written and marked untested; `hub_core_test` still passes.

**W1. Hashed URLs and `@asset`** (`cli/gweb.goose`, `cli/component.goose` two strings, `static.goose`, `test/templates/**`, `test/templates.sh`)
- Section 2.1 and 2.4: `Static` gains `hashed: u8[..520]`, the hashed alias in `gen_static`, `immutable` in `send_static` (pass `gz` as -1 for now), `GW_SCRIPT` and component URLs hashed, with the runtime generated before components and templates. `@asset` in `template_call`, `web::asset_url` generated in main, and the build errors.
- `component::compile` gets the runtime file name (`gwi.<h>.js`) as a new argument, and the component's own hashed URL is computed after its JS exists. The server render therefore needs it before writing `component()`. Compute the JS first, hash it, then emit the Goose `component()` line with the hashed name: change only the two string sites and the parameter list.
- Tests: `templates.sh` adds a page with `@asset("/site.css")` checked in `expect.html`; curl checks that the hashed URL gets `immutable` and the plain one `must-revalidate`; the two `@asset` errors. Check by eye that `components.sh` and `fragments.sh` still reference only names that exist (their expected files may contain `/_gw/gwi.js`: update them).
- Done: the suites pass with Goose, or the code is written and marked untested.

**W2. gzip and CSS minify** (`cli/gzip.c`, `cli/gzip_test.c`, `cli/gweb.build`, `cli/gweb.goose`, `static.goose`, tests)
- Section 2.2 and 2.3; `--no-minify` on `build` and `start`; `send_static` with `gz`.
- `cli/gzip_test.c`: round trip through zlib `uncompress`/`inflate`, byte-identical output for two runs, the 90% rule. It runs with `cc ... -lz`.
- `send_static` checks in templates.sh: `Accept-Encoding: gzip` gives `Content-Encoding: gzip` and `Vary`, while `gzip;q=0` gives plain, and both 304s.
- CSS minify cases: an `"a  b"` string kept, `url( x )` kept, `calc(1px + 2px)` kept, `/*! keep */` kept, nested braces, and an unbalanced file kept as is. Put the minifier in a function that can be tested by a `test_css` mode or a Goose test file.
- Done: `gzip_test` passes (must be tested); the rest passes with Goose or is marked untested.

**W3. `@image`, `ctx.meta`, `@meta()`** (`cli/gweb.goose`, `web.goose` `Ctx`, new `meta.goose`, tests)
- Section 3. The size readers are a gweb function `image_size(data) -> i64, i64, bool`. Test fixtures: one tiny PNG, GIF, JPEG, WebP and SVG each in `test/templates/site/public/img/` (make them with python3 or by hand), plus an `@2x` PNG.
- Tests: `expect.html` includes the `<img>` lines and the `@meta()` output from a page that sets every field; the error messages.
- Done: as for W1.

**W4. Sitemap and robots** (`cli/gweb.goose`, new `sitemap.goose` in goose-web, tests)
- Section 4. Generated routes go through the dispatcher's literal arms, ranked before user routes of the same URL, which is a build error anyway.
- Tests: a site with `app/sitemap.goose` adding one entry and one page with `const SITEMAP = false;`. Check `/sitemap.xml` and `/robots.txt` with `SITE_URL` set and unset, and that `public/robots.txt` wins.
- Done: as for W1.

**W5. Page cache and export** (`src/cache.c`, `web.build`, `web.goose` `Config`/`config_from_args`, `cli/gweb.goose` `gen_page_fn`/`gen_main`/commands, tests)
- Section 5. `src/cache.c` keeps its core in plain C with a `test/cache_test.c` (`cc` must pass: put, get, expiry with an injected clock, eviction order, the size cap).
- Tests: a `REVALIDATE = 2` page whose `load` returns a counter from `state` is the same on two GETs and changes after 3 s; 304 on If-None-Match; POST is not cached; a page that sets a cookie is not cached; the CSRF build error; `gweb export` output tree for the test site (`index.html`, one `static_paths` page, a static file at both names).
- Done: `cache_test` passes; the rest as for W1.

**W6. Streaming and the hub in goose-web** (`web.goose` `Ctx`/`Config`/`run_worker`, new `stream.goose` and `push.goose`, `cli/gweb.goose` `gen_main` and `socket.goose` handling, a test site `test/push/` and `test/push.sh`; needs N1 and N3)
- Sections 6 and 7.2. Pins: the goose-web test sites import goose-net by path, so they build against the worktree.
- Tests (`push.sh`): a streamed route read by `curl --raw` shows chunks; `subscribe` plus a POST that publishes gets the data to two `curl -N` clients; a WebSocket client in node (`node:net` with a hand-written handshake, no npm package) receives a publish and has its message echoed by `app/socket.goose`; a bad Origin gets 403, and an old version gets 426.
- Done: as for W1.

**W7. Docs** (`README.md`, `CHANGELOG.md`, `docs/ARCHITECTURE.md`, `docs/DEPLOY-PROXY.md`)
- `docs/DEPLOY-PROXY.md` from section 1. README sections: assets and caching, images and metadata, sitemap, page cache and export, streaming, WebSockets and the hub. ARCHITECTURE: the hub thread in the run-time diagram, and the static table rows. CHANGELOG `## Unreleased`.
- Done: every command in the new docs is copy-paste correct by reading; the Caddy and nginx configs pass `caddy validate` or `nginx -t` if those tools are installed, or are marked unchecked.

## 10. Risks

- **Nothing in Goose is compiled here.** Builders write against the APIs they read. Expect a fix-up pass once a compiler is available. The C cores are tested.
- **`gen_main` and `run_worker` are shared.** Five architects edit them, so merges are by hand. W6 keeps its `run_worker` change to one block after `apply_cookies`.
- **Hashed `/_gw/` names change every expected HTML file** in the suites that render components.
- **Per-worker page cache** means up to `workers` copies and renders per expiry, and a page that reads cookies leaks across users if someone marks it `REVALIDATE`. It is documented, and only setting cookies is caught.
- **Hub `poll`** is O(connections) per wake. That is fine to about 10,000 connections.
- **Origin check behind a proxy** needs the proxy to keep `Host` (Caddy does; the nginx config sets it).

## Open questions for the user

1. **Run-time compression.** I chose to leave HTML and JSON compression to the proxy. If you deploy without a proxy (a PaaS that ends TLS but does not compress), I would add `--gzip` with zlib in the server.
2. **Recommended proxy.** I chose Caddy, with nginx documented as well.
3. **CSS minify on by default** in `build` and `start`, with `--no-minify`. The other choice is off by default with `--minify`.
4. **`@asset` in components.** I chose not in v1, to avoid colliding with Addendum 12's rewrite of `component.goose`.
5. **`gweb export` URL shape.** I chose `about.html`. The other choice is `about/index.html`, which some hosts need. A `--dirs` flag could come later.
6. **Hub limits.** 10,000 connections, 64 KB messages, 1 MB output buffer, 30 s ping. Change them if your use cases differ.
