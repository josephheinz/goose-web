# Changelog

## v0.3.0 (unreleased)

Needs the matching goose-net release (spool mode, `net::Hub`, `Loop.detach`, chunked responses, `http::accepts`).

- Forms: a `*Form` struct in `page.goose` or `route.goose` gets a generated `decode`. New `web::valid`: `FieldErrors`, `check_email`, `check_range`, `check_length`, `check_one_of`, `field_error`, `invalid`, `field_value`, `errors_json`, `set_status`, `unprocessable`.
- 422: a form with errors answers 422. `gwi.js` morphs a 422 fragment reply instead of refusing it.
- Uploads: multipart posts, `web::Upload`, `save_upload`, `check_upload`, `const MAX_UPLOAD`. Flags `--max-upload N` (default 32 MiB) and `--upload-dir D` (default `.gooseweb.uploads`). Large bodies are spooled to disk. `gw-target` forms with `enctype="multipart/form-data"` send `FormData`.
- Error pages: `error.html` (nearest wins) and `web::fail`. A crashed request now gets the error page instead of hanging; `gweb dev` shows the abort text and source lines. Build errors in the dev overlay get source lines.
- `loading.html` and `gw-loading`: a loading state for slow fragment requests.
- A page `fn POST` or `fn load` may take `res`; `web::done(ctx)` ends the reply itself.
- Breaking: `web::Outcome` has two new variants, `Error` and `Done`. An exhaustive `match` on it needs arms for both.
- Behaviour change: when a worker crashes, its other keep-alive connections are now closed (they leaked before). Clients reconnect.
- `.env` files (`.env.<env>.local`, `.env.local`, `.env.<env>`, `.env`), `WEB_SECRET` with rotation, and typed `web::env_*` helpers.
- Signed cookies and stateless sessions: `web::login`, `logout`, `session`, `require_login`, `require_login_api`, `safe_next`.
- PBKDF2-HMAC-SHA-256 passwords: `web::password_hash`, `password_verify`, `password_needs_rehash`.
- Rate limits shared by all workers: `web::rate_limit`, `rate_limit_key`; `WEB_TRUST_PROXY` for `client_ip`.
- CORS: `web::cors`.
- CSP with a per-request nonce, opt-in with `WEB_CSP`; `web::nonce` for templates; optional `WEB_HSTS`.
- Behaviour change: every response now carries `X-Content-Type-Options`, `Referrer-Policy` and `X-Frame-Options` headers. Opt out with `WEB_SECURITY_HEADERS=0`.
- Behaviour change: `web::login` rotates the CSRF token.
- Apps that use sessions refuse to start in production without `WEB_SECRET`.
- Behaviour change: `/_gw/` URLs are hashed. Pages now load `/_gw/gwi.<hash>.js` and `/_gw/Name.<hash>.js`; the plain names still work. Expected HTML in tests that render components changes.
- Behaviour change: `gweb build`, `start` and `export` minify `public/**/*.css`. `gweb dev` does not. Pass `--no-minify` to keep the files as written.
- Static files are served at a hashed URL too (`/css/site.3f9a1c2b.css`) with `Cache-Control: public, max-age=31536000, immutable`. The plain URL is unchanged. A hashed URL that equals another URL is a build error.
- Text static files of 1 KB or more get a gzip variant at build time, sent to clients that accept it. gweb now links zlib.
- `@asset("/path")` writes the hashed URL; `web::asset_url(path)` does the same at run time.
- `@image(path, alt[, attrs])` writes an `<img>` with its size read at build time, lazy loading and an `@2x` `srcset`.
- `ctx.meta` with `web::meta_description`, `meta_canonical`, `meta_image` and `meta_robots`, and `@meta()` in `layout.html` for description, canonical, robots, Open Graph and Twitter tags. `web::site_url(req, out)` and the `SITE_URL` variable give the base URL.
- `app/sitemap.goose` turns on `/sitemap.xml` and `/robots.txt`; `web::sitemap_add` adds entries and `const SITEMAP = false;` leaves a page out.
- `const REVALIDATE = N;` in `page.goose` caches a page's GET reply per worker for N seconds, with an ETag. A page that uses a CSRF token cannot have it.
- `gweb export [-o DIR]` writes the site as static files. A dynamic page lists its paths in `fn static_paths()`.
- Streaming responses: `web::stream_begin`, `web::write` and `web::end(ctx, s)`.
- Server push: `web::subscribe` (SSE) and `web::websocket`, with `web::publish`, `web::send`, `web::close_socket` and `web::subscribers`, over one `net::Hub` thread. `app/socket.goose` handles `open`, `message` and `close`. `web::websocket` refuses a cross-origin `Origin`.
- New `Config` flag `--export DIR`; new `Ctx` fields `meta`, `hub`, `conn_fd`.
- New `docs/DEPLOY-PROXY.md`: Caddy and nginx in front of goose-web.
- Route tests: `web.testing` and `tests/*.goose`, run by `gweb test` against the real dispatcher with no socket.
- i18n: `locales/<tag>.txt` catalogs compile to a typed `t::` module; the locale comes from the `locale` cookie or `Accept-Language`.

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
