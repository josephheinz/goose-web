<!-- Produced by goose-architect on claude-opus-5-5 (medium) -->
# DESIGN-ADDENDUM-7: CSRF tokens (goose-web v0.2.0)

**Decision in one paragraph.** The token is a random 128-bit value (32 lowercase hex digits) kept in an HttpOnly cookie, `gw_csrf` (`__Host-gw_csrf` behind an HTTPS proxy). Forms send the same value back in a hidden `_csrf` field, and scripts send it in an `X-CSRF-Token` header. This is a double-submit cookie with no server secret. The check sits in one function, `web::csrf_ok`. Generated code calls it before any page `fn POST` and before any `route.goose` that defines `POST`, `PUT`, `PATCH` or `DELETE`. It replaces the v0.1 `Sec-Fetch-Site: cross-site` refusal and makes that refusal stricter: only `same-origin` and `none` pass. A route opts out with `const CSRF = false;`. Templates write `@web::csrf_field(ctx)`. `gwi.js` does not change (0 bytes).

## 1. Facts this design rests on

I read these. I did not run them.

- **The stdlib has no SHA-256 or HMAC** (DESIGN-ADDENDUM-5, "Signed sessions"). `os.random_seed()` returns 64 bits "for rng" (stdlib.md, line 1019), which is too few bits for a token.
- **goose-web has no server-side session store.** The only shared state is `app/state.goose` behind the owner thread.
- **`Ctx` is the only per-request carrier that templates can read.** Templates get `ctx: const web::Ctx&` (`gen()` signatures in `cli/gweb.goose`), so a template cannot set a cookie. Something with a mutable `ctx` must start the token before the render.
- **`@ns::f(a)` compiles to `ns::f(out, a);`** (`template_call`). Templates import `std`, `net.http`, `web` and `web.template` (`add_default_imports`). Generated `main.goose` also imports `web.form`.
- **gw-target form POSTs send the form's fields.** `frag()` in `client/gwi.js` builds the body with `new URLSearchParams(new FormData(el, e.submitter))`, so a hidden input goes with it. It uses `fetch` with the default credentials, so same-origin cookies are sent.
- **A non-2xx fragment reply throws in `frag()`.** The `gw:error` event fires, and the dev overlay shows it. The target keeps its content.
- **`http::set_header` appends and never replaces.** `fragment_reply` already sets `Cache-Control: no-store`, so a second setter would duplicate the line.
- **`http::text` appends to `res.body` and sets status and content type.** `http::json_error` clears the body first.
- **Browsers send `Sec-Fetch-Site` only to potentially trustworthy URLs** (HTTPS, or `localhost`). A plain-HTTP deployment on a LAN name or IP gets no Fetch Metadata. This is why the token is needed, and why Sec-Fetch-Site is only the second layer.
- **The earlier prototype** (`/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-csrf/goose-web/`) shows the following. Its transcript confirms each point.
  - `extern fn c_entropy(buf: u8[:]) -> i32 = "gweb_entropy";` compiles against `int32_t gweb_entropy(gweb_wbytes buf)`, where `typedef struct { uint8_t *data; int64_t len; } gweb_wbytes;`, and accepts a local `u8[..16]`.
  - A `csrf.goose` with `namespace web;` builds from a test program when it imports its sibling as `import .form;`. `import web.form;` inside the package failed with "cannot find the module web.form".
  - The fix for `eq_nocase` is `http::eq_nocase`. `diff |= a[i] ^ b[i]` needs no cast.
  - Its `csrf_test.goose` never compiled to the end, and no test ran. Treat its files as a starting point, not as verified code.

## 2. Decisions

### D1. Token model: double-submit cookie, random, no secret

- `web::csrf_begin` reuses the request's cookie when it holds a valid token. Otherwise it makes 16 bytes with `getentropy()` and stores them as 32 lowercase hex digits in `ctx.csrf`. It sets the cookie with `Path=/; HttpOnly; SameSite=Lax`, and with no `Max-Age`, so the cookie lasts for the browser session.
- `web::csrf_ok` passes an unsafe request only when the cookie holds a valid token and the sent token matches it byte for byte. The compare has no early exit.
- **One token per browser session.** It does not change per request or per form, so the back button, several tabs and fragment re-renders all keep working.
- **Reason.** Nothing else fits what goose-web has. There is no session store for a synchronizer token, no HMAC for a signed token, and Fetch Metadata alone is missing on plain HTTP. The value is opaque, which leaves room to change to a signed value later without changing the template or form API.

Rejected:
- **Synchronizer token in a server session.** goose-web has no session store, and an owner round trip on every page would be too costly.
- **Signed double-submit (HMAC with `WEB_SECRET`).** The stdlib has no HMAC, C crypto differs by platform, and there is no session to bind to. On HTTPS the only thing it adds is defence against cookie injection, and `__Host-` plus Sec-Fetch-Site already give that.
- **Fetch Metadata only, as in Go 1.25's `CrossOriginProtection`.** It gives no protection on plain HTTP outside localhost.
- **`Origin` against `Host`.** DESIGN-ADDENDUM-4 already rejected it, because proxies rewrite `Host`.
- **SameSite cookies alone.** They give no protection against same-site attackers, or for an app whose own cookies need `SameSite=None`.
- **A one-time token per request.** It needs server storage, and it breaks tabs, the back button and fragment replies.

### D2. Server secret: none

- `gweb dev` and `gweb start` provide nothing, and `Config` does not change.
- **Reason.** A double-submit token needs no secret. Because the token lives in the browser's cookie, a rebuild under `gweb dev` and a restart under `gweb start` keep forms that are already open working.
- The name `WEB_SECRET` stays reserved for signed sessions (DESIGN-ADDENDUM-5).

### D3. Cookie name and attributes

- `X-Forwarded-Proto: https` (trimmed) gives `__Host-gw_csrf` with `Secure`. Anything else gives `gw_csrf`.
- **Under HTTPS the plain `gw_csrf` cookie is ignored.** A sibling subdomain cannot set a `__Host-` cookie, so it cannot plant a token.
- Line without HTTPS: `Set-Cookie: gw_csrf=T; Path=/; HttpOnly; SameSite=Lax`.
- Line with HTTPS: `Set-Cookie: __Host-gw_csrf=T; Path=/; Secure; HttpOnly; SameSite=Lax`.
- **Lax, not Strict.** With Strict, a page opened from a link on another site would not receive the cookie. The page would then make a new token, and the forms already open in other tabs would fail.
- **HttpOnly.** A script gets the token from the page (D4), not from `document.cookie`.

Rejected:
- **A `Config` flag for HTTPS.** Every deployment would have to set it. The proxy header is already there.

### D4. How templates and scripts get the token

Two functions are added to `template.goose`, which every template already imports:

```goose
fn csrf_field(out: u8[>..]&, ctx: const Ctx&)      // <input type="hidden" name="_csrf" value="T">
fn csrf_token(ctx: const Ctx&) -> const u8[:]      // T; "" when the page did not start a token
```

- **In a form:** `<form method="post" action="/x">@web::csrf_field(ctx) ...</form>`.
- **For scripts:** `<meta name="csrf-token" content="{web::csrf_token(ctx)}">`, and the script sends `X-CSRF-Token` with that value.
- **The spelling is `@web::csrf_field(ctx)`, not `@web::csrf_field()`.** The rule `@f(a)` → `f(out, a)` stays uniform, and templates have no hidden arguments.

**Who starts the token.** `gweb` scans the source text for `web::csrf_`. For a page, it emits `if !web::csrf_begin(req, ctx, res) { return; }` right after `web::html(res, http::Status.Ok);` when that text is in any of these:
- its `page.html`;
- its `page.goose`;
- any `layout.html` that wraps it.

The same scan covers `not-found.html` and the root layout, for the 404 path in `finish` (section 4).

- **A lib partial that writes the field is not seen by the scan.** For that case, and for a whole admin subtree, `web::csrf_begin(req, ctx, res)` is public. `before` middleware calls it. It does nothing when the token is already started.
- **`csrf_begin` adds `Cache-Control: no-store`** (once, through `web::no_store`). A page with a per-browser token must not sit in a shared cache. Pages that do not use a token are unchanged: no cookie, no header, the same bytes.

Rejected:
- **Start a token on every HTML response in `run_worker`.** It would put `Set-Cookie` and `no-store` on the benchmark pages and break the "no Set-Cookie on `/products/42`" check.
- **Make `csrf_field` start the token.** The template's `ctx` is const, and the cookie lines must be in `ctx` before the render.
- **A build error for a POST form without the field.** Forms span lines and can post to another page, so the check would be fragile. The 403 text names the fix instead.

### D5. What carries the token, request by request

| Request | Carries | Checked by |
|---|---|---|
| Page `fn POST`, whole page | the hidden `_csrf` field (urlencoded body) | generated `page_N`, before `before` middleware |
| gw-target form POST (fragment) | the same field, sent by gwi.js's `FormData` | the same `page_N` line |
| `route.goose` `POST`, `PUT`, `PATCH`, `DELETE` from an HTML form | the `_csrf` field | generated `route_N`, its first statement |
| The same methods from a script (`fetch`) | the `X-CSRF-Token` header | the same line |
| `GET`, `HEAD`, `OPTIONS`, and unknown methods (which get 405) | nothing | passes |

- **When `X-CSRF-Token` is present, only the header is read**, even if the body also has a field. Otherwise the `_csrf` field of the body is read with `web::form`. The content type is not checked: a body that is not urlencoded simply has no `_csrf` pair, and that fails closed.
- **`_csrf` becomes a reserved form field name.** Handlers can still read it, and it does no harm.
- **The check runs before `before` middleware**, so a forged request has no side effect at all: no sliding session and no cookie.

### D6. gwi.js: no change

- **Bytes:** gwi.min.js stays at 3,133 of 3,584.
- **Reason.** The hidden field already travels in the fragment POST body, and `fetch` already sends the cookie.
- **Failure:** a token failure on a fragment POST is a 403. The existing path handles it: an `Error("fragment NAME: 403 from /path")`, then `gw:error`, then the dev overlay. The target keeps its content.

Rejected:
- **gwi.js adds `X-CSRF-Token` from a meta tag.** Forms must work without JavaScript, so they need the field anyway. It would also cost bytes in the file that Addendum 9 is editing.
- **On a 403, fall back to a full navigation.** It costs bytes for an error that only shows up in development, or after a browser restart.

### D7. Failure response

- **Status and type:** `403`, `text/plain; charset=utf-8`, written by `http::text`. There is no `Set-Cookie`, because the check runs before middleware and handlers.
- **Wrong or missing token:** `CSRF token missing or wrong; reload the page and try again\n`
- **Refused by Sec-Fetch-Site:** `cross-site request refused\n`
- **Reason.** Each message tells the user what to do, and a developer can tell the two causes apart. The plain-text style matches the existing `404 not found\n`.
- **If `csrf_begin` cannot make or set a token** (getentropy fails, or the 2048-byte cookie buffer is full), it sends `500` through `http::json_error(res, InternalServerError, "csrf token unavailable")`.

### D8. Relation to the `Sec-Fetch-Site` 403

- `web::csrf_ok` does this, in this order, for unsafe methods:
  1. **Fetch Metadata.** A `Sec-Fetch-Site` header that, after trimming, is not `same-origin` or `none` gives the cross-site 403. This covers both `cross-site` and `same-site`.
  2. **The token.**
- **No header passes to step 2.** That covers old browsers, plain HTTP, and clients that are not browsers.
- **The generated `web::cross_site` call goes away, and so does `web::cross_site` in `form.goose`.** It was documented as being for generated code only. `gweb` and the runtime are pinned to the same tag, so nothing else calls it.
- **Why also refuse `same-site`.** On HTTPS it stops a sibling subdomain from planting a token cookie and posting with it, which is the classic weakness of double-submit.
- **Why keep the token at all.** Fetch Metadata does not reach a plain-HTTP deployment.

Rejected:
- **Keep the v0.1 rule** (refuse only `cross-site`). It leaves the subdomain attack open on HTTPS.

### D9. Opt-out per route

- **Spelling:** a `route.goose` may declare `const CSRF = false;` on a line of its own. A trailing comment is allowed. The route is then on its own: **neither the token check nor the Sec-Fetch-Site check runs.**
- **Use it for:**
  - APIs called by clients that are not browsers;
  - webhooks;
  - cross-site browser callbacks, such as an OIDC `form_post`, a 3-D Secure return or a SAML POST binding. These are cross-site by nature, so a partial opt-out would still refuse them.
- **The rule for app authors:** a route that opts out must not trust cookies for authority.
- **Validation by gweb.** A trimmed line that starts with `const CSRF` must start with `const CSRF = false;` or `const CSRF = true;`. Otherwise:
  `app/x/route.goose:N: error: write const CSRF = false; to turn off this route's CSRF check (or const CSRF = true;)`
- **`const CSRF` in a `page.goose`:**
  `app/x/page.goose:N: error: const CSRF belongs in route.goose; a page's POST always checks the token`
- **Generated code references the constant**, so it is type-checked and never unused:
  ```goose
  if r3_api_todos::CSRF && !web::csrf_ok(req, res) { return; }
  ```
  Without the constant, a route that defines POST, PUT, PATCH or DELETE gets `if !web::csrf_ok(req, res) { return; }`. A route with only GET, HEAD or OPTIONS and no constant gets no line.
- **A misspelt constant** (`const CRSF = false;`) leaves the check on. That fails safe, and the error is visible as a 403.
- **Pages have no opt-out.**

Rejected:
- **Opt-out by folder (`app/api/**`).** It is implicit: an HTML form under `/api` would lose its protection without notice.
- **Opt-out by a marker comment.** Comments as configuration go stale, and the compiler never checks them.
- **The opt-out keeps the Sec-Fetch-Site check.** That blocks the cross-site callbacks above.
- **Skip the check when the request has no `Cookie` header.** It misses login CSRF, HTTP auth and IP-trusted intranets.

### D10. Breaking change, on by default

- In v0.2.0, every page POST and every unsafe `route.goose` method is checked. An app updated from v0.1.x answers 403 until its forms add `@web::csrf_field(ctx)`, or its API routes declare `const CSRF = false;`.
- The CHANGELOG states this as the first v0.2.0 item.

## 3. Runtime code

### `src/sys.c`

- Add `#include <unistd.h>`, and `#include <sys/random.h>` under `__APPLE__`.
- Add the function below. getentropy refuses more than 256 bytes per call, which is why the length is bounded.

```c
typedef struct { uint8_t *data; int64_t len; } gweb_wbytes;

int32_t gweb_entropy(gweb_wbytes buf) {
    if (buf.len < 0 || buf.len > 256) return 0;
    return getentropy(buf.data, (size_t)buf.len) == 0;
}
```

### `web.goose`: one line, nothing else

In `struct Ctx`, directly after the `fragment: bool = false, ...` line:

```goose
    csrf: u8[..32] = "",      // the page's CSRF token; "" until web::csrf_begin
```

`new_ctx` stays as it is, because the default fills the field.

### `form.goose`

- Add `fn no_store(res: http::Response&)`. It adds `Cache-Control: no-store` unless `res.headers` already holds that line.
- `fragment_reply` calls `no_store(res)` in place of its `set_header` line.
- Delete `cross_site`.

### `template.goose`

- Add `csrf_field` and `csrf_token` (D4), at the end of the file.
- `csrf_field` writes exactly `<input type="hidden" name="_csrf" value="` + `ctx.csrf` + `">`. Hex needs no escaping.

### New `csrf.goose` (`namespace web;`)

- Imports: `std`, `net`, `net.http`, `web`, and `.form`, as the prototype found. See E3.
- Contents:

```goose
extern fn c_entropy(buf: u8[:]) -> i32 = "gweb_entropy";

// "__Host-gw_csrf" behind an HTTPS proxy (X-Forwarded-Proto), else "gw_csrf".
fn csrf_cookie_name(req: const http::Request&) -> const u8[:]
// Exactly 32 lowercase hex digits.
fn csrf_valid(t: const u8[:]) -> bool
// Reuses the request's token or makes one; false after writing a 500.
fn csrf_begin(req: const http::Request&, ctx: Ctx&, res: http::Response&) -> bool
// True for GET, HEAD, OPTIONS and Other; for the rest, false after writing the 403 of D7.
fn csrf_ok(req: const http::Request&, res: http::Response&) -> bool
fn token_equal(a: const u8[:], b: const u8[:]) -> bool   // no early exit, so timing does not tell how many bytes matched
```

- **Start from the prototype `csrf.goose`, with these changes:**
  - the messages of D7;
  - no content-type test before `web::form`;
  - no `csrf_token` or `csrf_field` (they move to `template.goose`);
  - `step 1` refuses any `Sec-Fetch-Site` other than `same-origin` or `none`. The prototype already does this.
  - `csrf_begin` returns at once when `ctx.csrf.len > 0`, then calls `no_store(res)`.
- **Code style:** only why-comments and one-line API notes.

## 4. Generator changes (`cli/gweb.goose`)

Exact edit regions. Each one is a small hunk, so a merge with Addendum 8 stays local.

1. **`struct Dir`.** Add one new line as the last field line, with defaults, so that the literal in `scan_dir` does not change:
   ```goose
   page_csrf: bool = false, layout_csrf: bool = false, csrf_const: bool = false
   ```
   Add a comma to the line before it.
2. **New helpers, placed directly after `fn defines`:**
   - `fn mentions_csrf(src: const u8[:]) -> bool`: `find(src, "web::csrf_") >= 0`.
   - `fn csrf_const(path: const u8[:], code: const u8[:], route: bool) -> bool`: it applies the D9 line rule, and calls `err` with the D9 messages.
3. **`gen()`:**
   - **Route block:** after the methods loop, `d.csrf_const = csrf_const(src, code, true);`.
   - **Layout block:** read the source and set `d.layout_csrf`.
   - **Page block:** call `csrf_const(src, code, false)` for its error only. Set `d.page_csrf` from `page.goose`'s code and from `page.html`'s source.
   - **Not-found block:** set a new global `not_found_csrf`, declared beside `has_not_found`.
4. **`gen_page_fn`:**
   - **After** `m.append("    }\n");`, which closes the method match, emit `    if !web::csrf_ok(req, res) { return; }\n`, only when `d.has_post`.
   - **After** the `web::html(res, http::Status.Ok);` line, emit `    if !web::csrf_begin(req, ctx, res) { return; }\n` when `d.page_csrf`, or when some `o` with `o.layout && o.layout_csrf && is_ancestor(o.rel, d.rel)` exists.
   - **Delete** the `web::cross_site` line.
5. **`gen_route_fn`:** directly after the `fn route_` header line, and before `middleware_before`, emit the D9 line.
6. **`gen_finish`, NotFound branch:** when `not_found_csrf` is true or the root layout has `layout_csrf`, wrap the render statement in `if web::csrf_begin(req, ctx, res) { ... }`.
7. **`gen_main`:** emit `import web.csrf;\n` on a line of its own, directly after the line that ends `import web.form;\n`.

**Untouched:**
- `scan_dir`, `dispatch_order`, `match_url`, `check_targets`, `gen_dispatch`, `print_routes`;
- `scan_targets`, `compile_template`, `template_call`, `add_default_imports`;
- the scaffold.

The template files that gweb generates do not change, so `test/fragments/expect_p5_plain_html.goose` still matches.

### Generated `page_N` for a POST page that renders a token

```goose
    match req.method { /* as today */ }
    if !web::csrf_ok(req, res) { return; }
    /* before middleware */
    web::html(res, http::Status.Ok);
    if !web::csrf_begin(req, ctx, res) { return; }
    let part = web::fragment_index(req, ["todo-list"]);
    if req.method == http::Method.Post {
        let props = p17_fragments::POST(req, ctx);
        /* as today */
```

## 5. Files

**goose-web, changed:**
- `src/sys.c`
- `web.goose` (one line)
- `form.goose`
- `template.goose`
- `cli/gweb.goose`
- `test/fragments.sh`
- `test/fragments/site/app/page.html`
- `test/release_check.sh`
- `README.md`
- `CHANGELOG.md`

**goose-web, created:**
- `csrf.goose`
- `test/csrf_test.goose`
- `test/fragments/site/app/save/route.goose`
- `test/fragments/site/app/webhook/route.goose`

**Lab repo, changed:**
- `examples/shop/app/fragments/page.html`
- `examples/shop/app/cookies/page.html`
- `examples/shop/app/api/todos/route.goose`
- `examples/shop/app/api/todos/[id]/route.goose`
- `goose-bench/shop/check_site.py`
- `goose-bench/shop/bench_shop.py`

**Not touched:**
- `client/gwi.js`, `client/gwi.min.js`
- `owner.goose`, `static.goose`
- `cli/component.goose`, `cli/tscan.goose`
- `docs/ARCHITECTURE.md`
- goose-net, goose-sqlite
- the shop's `layout.html`, `/products` pages and `components/`

### Edit regions in the shared files

- **`web.goose`:** the one `Ctx` line after `fragment`. If Addendum 10 needs a `Ctx` field, put it anywhere except the line directly after `fragment`.
- **`client/gwi.js`:** none.
- **`README.md`:**
  - (a) A new `## CSRF` section between the end of `## Cookies` and `## Fragments`.
  - (b) In `## Fragments`, replace only the sentence "A POST with `Sec-Fetch-Site: cross-site` gets 403; other methods get 405." with "A POST must carry the CSRF token (see CSRF); other methods get 405." This sentence is next to the morph bullet that Addendum 9 rewrites, so a merge there may need a hand join of two neighbouring lines.
  - Nothing else.
- **`check_site.py`:**
  - (a) In the docstring, one usage line after the `--fragments` usage line, and one paragraph after the `--fragments` paragraph.
  - (b) `CSRF = "--csrf" in sys.argv[1:]` and `TOKEN = "0123456789abcdef0123456789abcdef"`, on the two lines directly after `FRAGMENTS = ...`.
  - (c) Inside `# Cookies`: `call_cookies` and its four POST calls.
  - (d) Inside `# Fragments`: `frag()`, the first `call("GET", "/fragments")`, and the cross-site check.
  - (e) A new `# CSRF` block between the end of the Cookies block and `# Components`.
- **`bench_shop.py`:** one `args.append("--csrf")` after `args.append("--fragments")`.

## 6. Shop

- **`app/fragments/page.html`, line 4:** `<form method="post" action="/fragments" gw-target="todo-list">@web::csrf_field(ctx)`. The field is inside the fragment, so it comes back in every fragment reply.
- **`app/cookies/page.html`:** the three forms become `<form method="post" action="...">@web::csrf_field(ctx)<button ...>`. The theme and reset routes stay checked. They are the demo of a route POST that a form submits.
- **`app/api/todos/route.goose` and `app/api/todos/[id]/route.goose`:** add `const CSRF = false;` after the imports, with the why-comment `// A JSON API for scripts and check_site.py; it trusts no cookie.` These are what keep the base `check_site.py` run, which also runs against the Next.js twins, unchanged.
- **The benchmark.** `/products/42` and every other benchmark URL generate the same code and bytes. They have no POST and no token, and the root layout does not use one. The "no Set-Cookie" checks still hold.

## 7. Tests

### `test/csrf_test.goose` (new; 52 checks; the same harness as `cookie_test.goose`, no sockets)

The rows below are numbered 1 to 52. Each row is one `check`.

**`csrf_valid`:**
1. 32 lowercase hex: true
2. 31 digits: false
3. 33 digits: false
4. uppercase hex: false
5. a `g` in it: false
6. empty: false

**`csrf_cookie_name`:**
7. no `X-Forwarded-Proto`: `gw_csrf`
8. `https`: `__Host-gw_csrf`
9. ` https ` with spaces: `__Host-gw_csrf`
10. `http`: `gw_csrf`

**`csrf_begin`, no cookie:**
11. returns true
12. `ctx.csrf` is valid
13. `set_cookies` is exactly `Set-Cookie: gw_csrf=T; Path=/; HttpOnly; SameSite=Lax\r\n`
14. `res.headers` holds `Cache-Control: no-store` exactly once

**`csrf_begin`, called again on the same ctx:**
15. true, and the same token
16. still one `Set-Cookie` line and one `Cache-Control` line

**Fresh tokens:**
17. two fresh ctxs get different tokens
18. a token is not 32 zeros

**A valid cookie:**
19. reused
20. no `Set-Cookie`
21. `no-store` is still set

**An uppercase (invalid) cookie:**
22. replaced: a new token and a `Set-Cookie` line

**HTTPS:**
23. the exact line `Set-Cookie: __Host-gw_csrf=T; Path=/; Secure; HttpOnly; SameSite=Lax\r\n`
24. with only a plain `gw_csrf` cookie, a new `__Host-` token is made, not the plain one reused

**A full cookie buffer** (fill `set_cookies` with two 1000-byte cookies first):
25. returns false
26. status 500 and `ctx.csrf` empty

**`fragment_reply` after `csrf_begin`:**
27. one `Cache-Control` line

**`csrf_field` and `csrf_token`:**
28. `csrf_field` gives the exact bytes
29. `csrf_token` equals `ctx.csrf`
30. before `csrf_begin`, `csrf_field` gives `value=""`

**`csrf_ok`:**
31. GET with nothing: true, `res` untouched
32. HEAD: true
33. OPTIONS: true
34. POST, cookie plus a matching `_csrf` field: true
35. POST, cookie plus a matching header: true
36. a wrong header with a right field: false (the header wins)
37. no cookie: false, status 403
38. a cookie and no token: false
39. a one-digit mismatch: false
40. cookie and field both `abc` (equal, but invalid): false
41. the token 403 body is exact
42. `Sec-Fetch-Site: cross-site` with a good token: false, and the exact cross-site body
43. `same-site` with a good token: false
44. `same-origin` with a good token: true
45. `none` with a good token: true
46. PUT without a token: false
47. PATCH without a token: false
48. DELETE without a token: false
49. a JSON body with the header: true
50. HTTPS with a plain `gw_csrf` cookie and the token: false
51. HTTPS with `__Host-gw_csrf`: true
52. the field among others, `title=x&_csrf=T&add=1`: true

**Run:** `goose build test/csrf_test.goose && test/csrf_test` prints `52 of 52`.

### `test/fragments.sh` (69 to 82)

**Set-up:** `TK=0123456789abcdef0123456789abcdef`.
- Every existing `GET /` request (`whole`, `list`, `side`, `nope`) gets `-H "Cookie: gw_csrf=$TK"`, so the substring and `cmp` checks compare the same token.
- Every existing `POST /` gets `-H "Cookie: gw_csrf=$TK" -d "_csrf=$TK"`.
- The `xs` check also requires the body `cross-site request refused`.
- **The site:**
  - `app/page.html` line 2 becomes `<form method="post" action="/" gw-target="list">@web::csrf_field(ctx)`. The existing `body_has list '<form ...>'` check still matches.
  - `app/save/route.goose`: `fn POST` writes `saved\n`.
  - `app/webhook/route.goose`: `const CSRF = false;`, and `fn POST` writes `hook\n`.
  - Both folders sort after `plain`, so `p5_plain` keeps its index.

**New checks:**

| # | Request | Expect |
|---|---|---|
| 70 | `GET /` with no cookie | one `set-cookie: gw_csrf=` line of 32 hex digits, `; path=/; httponly; samesite=lax`; `cache-control: no-store`; the body has `name="_csrf" value="` |
| 71 | `GET /` with the cookie | no `set-cookie`; the body has `value="$TK"` |
| 72 | `GET /plain` | no `set-cookie`, no `cache-control` |
| 73 | `POST /` without a token | 403; the body has `CSRF token missing or wrong` |
| 74 | `POST /` with the cookie and `_csrf=` one digit off | 403 |
| 75 | `POST /` with the cookie and `X-CSRF-Token: $TK`, no field | 200 |
| 76 | `POST /` with a good token and `Sec-Fetch-Site: same-site` | 403; `cross-site request refused` |
| 77 | `POST /save` without a token | 403 |
| 78 | `POST /save` with the cookie and the header | 200, `saved` |
| 79 | `POST /webhook` with no token and `Sec-Fetch-Site: cross-site` | 200, `hook` |
| 80 | `grep` of `$WORK/ok/.gooseweb/main.goose` | it has `::CSRF && !web::csrf_ok(req, res)` |
| 81 | `expect_fail bare:app/api/route.goose 'const CSRF = 0;'`, line 1 | the D9 route message |
| 82 | `expect_fail bare:app/page.goose 'const CSRF = false;'`, line 1 | the D9 page message (other errors may follow; the match is a substring) |

### `test/release_check.sh`

- Add `csrf_test()`. It is a copy of `cookie_test()` for `csrf_test.goose`, with the same `sed` lines.
- Add `step csrf_test csrf_test` directly after `step cookie_test cookie_test`.

### `check_site.py`

- **`call_cookies(method, path, cookie=None, token=False)`:**
  - With `token`, it appends `gw_csrf=TOKEN` to the `Cookie` header (`; ` between pairs) and sends the body `_csrf=TOKEN` as `application/x-www-form-urlencoded`.
  - It drops `Set-Cookie` values that start with `gw_csrf=` before it returns, so the exact lists in the Cookies block stay as they are.
  - The four POST calls pass `token=True`.
- **`frag()`:**
  - Always sends `Cookie: gw_csrf=TOKEN`.
  - Appends `&_csrf=` + TOKEN to `raw` for POST.
  - The first `call("GET", "/fragments")` becomes `frag("/fragments", None)`.
  - The cross-site check also requires the body `cross-site request refused\n`.
- **New `--csrf` block.** Its own helper returns status, headers, all `Set-Cookie` values and body.
  1. `GET /cookies` with no cookie: exactly one `gw_csrf` value, matching `^gw_csrf=[0-9a-f]{32}; Path=/; HttpOnly; SameSite=Lax$`; `Cache-Control: no-store`; the body has `<input type="hidden" name="_csrf" value="T">` 3 times, where `T` is the cookie's value.
  2. `GET /cookies` with `Cookie: gw_csrf=TOKEN`: no `gw_csrf` `Set-Cookie`; `value="TOKEN"` 3 times.
  3. `Cookie: gw_csrf=ZZ`: a new `gw_csrf` value, not `ZZ`.
  4. `X-Forwarded-Proto: https`: a value matching `^__Host-gw_csrf=[0-9a-f]{32}; Path=/; Secure; HttpOnly; SameSite=Lax$`.
  5. `POST /cookies/reset` with no cookie and no field: 403, `text/plain`, the body exactly `CSRF token missing or wrong; reload the page and try again\n`, and no `Set-Cookie` at all.
  6. The cookie only: 403.
  7. The field only: 403.
  8. Cookie and field differ: 403.
  9. The cookie plus `X-CSRF-Token: TOKEN`, no body: 303.
  10. Cookie, field and `Sec-Fetch-Site: same-site`: 403, the body exactly `cross-site request refused\n`.
  11. The same with `same-origin`: 303.
  12. `X-Forwarded-Proto: https`, a plain `gw_csrf` cookie and the field: 403. The same with `__Host-gw_csrf=TOKEN`: 303.
  13. `POST /fragments` with no token: 403.
  14. `PUT /api/todos/999999` with a JSON body, `Sec-Fetch-Site: cross-site` and no token: 404. This shows the opt-out is complete.
  15. `POST /api/todos` with `{"title": ""}`, `Sec-Fetch-Site: cross-site` and no token: 400. No todo is made, so the Fragments block's "three seeds" check still holds.
  16. `/products/42` and `/fragments/products` send no `gw_csrf` value.

**Unchanged:** components.sh 41, templates.sh 33, cookie_test 59, test_net 142.

## 8. Browser test lines (`gweb dev` in the shop, a fresh profile)

1. Open `/cookies`. DevTools, Application, Cookies shows `gw_csrf`: 32 hex digits, HttpOnly, Session, SameSite Lax. View source has three `name="_csrf"` inputs with that value, and the document response has `Cache-Control: no-store`.
2. Click **Dark**. The page comes back dark.
3. Delete `gw_csrf` in DevTools and click **Light** without reloading. The page is plain text: "CSRF token missing or wrong; reload the page and try again". Go back, reload, and click **Light**: it works, and there is a new `gw_csrf`.
4. In Elements, change the last digit of one hidden `_csrf` value and click its button. You get the same 403 text.
5. Open `/fragments` and add a todo. The list updates in place. In Network, the request payload has `_csrf`, the request headers have `Sec-Fetch-Site: same-origin`, and the status is 200.
6. Delete `gw_csrf` and add another todo. The list does not change, the console logs `fragment todo-list: 403 from /fragments`, and the dev overlay shows it as a page error. Reload, and adding works again.
7. Cross-origin form:
   - Serve a page from another port: `python3 -m http.server 8000` in a scratch folder that holds `<form method="post" action="http://localhost:60053/cookies/reset"><input name="_csrf" value="x"><button>go</button></form>`.
   - Submit it. You get 403 "cross-site request refused". The ports differ but the host is the same, so the browser sends `same-site`.
8. In a fresh profile, open `/products/42` with Network open. There is no `Set-Cookie`, and no `gw_csrf` exists afterwards.
9. `/components`: Counter and TodoBox still work. The console has no errors on `/fragments` or `/components`.

## 9. Builder plan (Sonnet 5.5, medium)

**Rules for every step:**
- One commit per step. goose-web commits go in `/Users/joeheinz/Documents/goose/goose-web`. Lab commits go in `/Users/joeheinz/Documents/goose`.
- `GOOSE=/Users/joeheinz/Documents/goose/goose-sdk/goose-v2026.4-macos-arm64/goose`.
- Rebuild gweb with `$GOOSE build -o gweb cli/gweb.goose` from goose-web whenever `cli/` changes.
- Comments: why-comments and one-line public API notes only. No comments that restate code, tell history or cite this document.
- Stop and report if a check fails twice, or if an experiment gives the outcome marked "stop".

### Phase 0: experiments in a scratch copy (no commit)

Copy goose-web and goose-net to the scratchpad. Start from the prototype files listed in section 1.

- **E1, the opt-out constant.**
  - **Set-up:** in a scratch gweb project, a `route.goose` with `const CSRF = false;` and `fn POST`, and hand-edit the generated `main.goose` line to `if rN_x::CSRF && !web::csrf_ok(req, res) { return; }`, then build.
  - **Outcomes:**
    - (a) It builds with no warning: as designed.
    - (b) `const` with a bool initializer is refused: use `let CSRF = false;` everywhere in this design (detection, messages, docs) and retry.
    - (c) A warning about a constant condition: emit no line when the value is `false`, and confirm that an unused `const CSRF = false;` builds with no warning. If that warns too, **stop**.
- **E2, entropy.**
  - **Set-up:** build csrf.goose and a 3-line program that calls `csrf_begin` twice on fresh ctxs and prints the tokens.
  - **Outcome:** two different 32-hex tokens, not all zeros. Anything else: **stop**.
- **E3, the sibling import from a git source.**
  - **Set-up:** publish the scratch goose-web into a local bare repo with a tag, as `publish` in `release_check.sh` does. Then build a program that has `import web from "file://...@tag"; import web.csrf;` and calls `web::csrf_valid("")`.
  - **Outcomes:**
    - It builds: keep `import .form;`.
    - It fails: put the contents of `csrf.goose` at the end of `form.goose` instead, under the same names. Drop `csrf.goose`, the `gen_main` import line, and `import web.csrf;` from the tests.

Report E1 to E3 in two lines each before step 1.

### Phase 1: runtime (goose-web)

**Step 1, commit "Add gweb_entropy, Ctx.csrf and web::no_store".**
- Files: `src/sys.c`, the one `web.goose` line, and `form.goose` (`no_store`; `fragment_reply` uses it). Do not delete `cross_site` yet.
- Checks:
  - `$GOOSE build test/cookie_test.goose && test/cookie_test`: 59 of 59;
  - `GOOSE=$GOOSE sh test/components.sh`: 41;
  - `test/templates.sh`: 33;
  - `test/fragments.sh`: 69.

**Step 2, commit "Add web.csrf: a double-submit token checked on unsafe methods".**
- Files: `csrf.goose` (section 3), `csrf_field` and `csrf_token` in `template.goose`, `test/csrf_test.goose` (the 52 rows), and the `release_check.sh` step.
- Checks:
  - `test/csrf_test`: 52 of 52;
  - cookie_test 59;
  - `GOOSE=$GOOSE sh test/release_check.sh` ends with `all passed`.

### Phase 2: generator (goose-web)

**Step 3, commit "gweb: check CSRF on page POST and route writes; start tokens for pages that render them".**
- Files: `cli/gweb.goose` (section 4, regions 1 to 7), deletion of `cross_site` from `form.goose`, the `test/fragments.sh` edits and the new site files (section 7).
- Checks:
  - rebuild gweb;
  - fragments.sh: 82 passed, 0 failed;
  - components 41;
  - templates 33;
  - csrf_test 52;
  - cookie_test 59;
  - release_check all passed.
- **Generated-code check:**
  - Run `./gweb -C ../examples/shop gen`, then read `.gooseweb/main.goose`.
  - The `/products/[id]` page function has no `csrf_` line.
  - `/fragments` has `csrf_ok` before middleware and `csrf_begin` after `web::html`.
  - The two `api/todos` routes start with `::CSRF && !web::csrf_ok`.
  - `cookies/reset` starts with `if !web::csrf_ok(req, res) { return; }`.

**Step 4, commit "Document CSRF".**
- **`README.md` regions (a) and (b).** The section covers:
  - the model in two sentences;
  - `@web::csrf_field(ctx)`, and the meta tag plus `X-CSRF-Token` for scripts;
  - when gweb starts the token, and `web::csrf_begin` in middleware for lib partials;
  - the 403 texts;
  - Sec-Fetch-Site;
  - `const CSRF = false;` and its rule (the route must not trust cookies);
  - `__Host-` behind `X-Forwarded-Proto: https`;
  - `Cache-Control: no-store` on token pages.
- **`CHANGELOG.md`:** a `## Unreleased` heading, if none exists, whose first bullet is the breaking change of D10.
- Checks: release_check all passed. Read both diffs once for accuracy against sections 2 and 7.

### Phase 3: shop and checks (lab repo)

**Step 5, commit "shop: CSRF fields in the demo forms; the todo API opts out; check_site --csrf".**
- Files: section 6 shop files, `check_site.py` (section 5 regions a to e, section 7), and `bench_shop.py`. This is one commit, because after step 3 the old checks fail without these edits.
- Checks:
  - Start the shop: `../goose-web/gweb -C examples/shop start --port 3300`.
  - `python3 goose-bench/shop/check_site.py http://localhost:3300 --components --cookies --fragments --csrf`: no `FAIL` lines and exit 0. This includes `/products/42` byte-identical to `baseline/products_42.html`.
  - `python3 goose-bench/shop/check_site.py http://localhost:3300` (base): exit 0.
  - `../goose-web/gweb -C examples/shop test`: passes.
  - Stop the server.

### Phase 4: browser (no commit)

Run section 8 in the browser pane against `gweb dev` and report each line as pass or fail.

## 10. Risks

- **Breaking for v0.1 apps** (D10). Every unsafe form and route answers 403 until it is updated.
- **Plain HTTP with sibling subdomains.** A sibling host can set `gw_csrf` for the parent domain. Over HTTP there is no `__Host-` and no Sec-Fetch-Site, so it can forge requests. The fix is HTTPS, or the signed-token follow-up.
- **Lib partials are not detected.** A page that renders the field only through a `lib/` function gets `value=""` and a 403, until `before` middleware calls `web::csrf_begin`.
- **No rotation.** The token lives as long as the browser session, and login does not rotate it. Rotation belongs with sessions; the name `web::csrf_rotate` is reserved.
- **`X-Forwarded-Proto` is trusted.** A proxy that does not set it gives a plain, non-Secure cookie. A client that fakes it over direct HTTP only breaks its own posts.
- **A lost session cookie.** After a browser restart with no session restore, an old tab's POST gets 403. A reload fixes it. A fragment POST fails without a visible message in production.
- **Route writes now refuse `same-site` and `cross-site` browsers.** A CORS API used by browsers on other sites needs `const CSRF = false;`.
- **Linux is untested.** `getentropy` needs glibc 2.25 or later, through `<unistd.h>`.
- **Costs.** `Ctx` grows by 40 bytes. Token pages are `no-store`. `HEAD` on a token page also makes a token. A page that reaches `web::not_found` after `csrf_begin` still sends the cookie.
- **Text scan.** The scan for `web::csrf_` also matches a mention in a comment. That only starts a token where none is needed.

## 11. Decisions for the user

1. **CSRF on by default** for page POST and for `route.goose` POST, PUT, PATCH and DELETE, which breaks v0.1 apps (D10). The alternative is opt-in per route.
2. **`const CSRF = false;` turns off both checks** for a route (D9). The alternative keeps Sec-Fetch-Site and blocks cross-site callbacks.
3. **Refuse `Sec-Fetch-Site: same-site`** as well as `cross-site` (D8).
4. **No server secret and no signed token in v0.2.0**, accepting the plain-HTTP subdomain risk (D1, D2).
5. **Template spelling `@web::csrf_field(ctx)`** with an explicit `ctx`, not `@web::csrf_field()` (D4).
6. **The wording of the two 403 bodies** (D7), which end users see.
7. **Remove `web::cross_site`** rather than keep it (D8).
8. **The shop's `/api/todos` routes opt out**, while the cookie demo routes stay checked (section 6).
