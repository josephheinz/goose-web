<!-- Produced by goose-architect on claude-fable-5-2 -->
# DESIGN-ADDENDUM-5: cookies

**Decision:** cookies are read from `req` and set through `ctx`. `Ctx` gains one flat field, `set_cookies: u8[..2048]`, that holds finished `Set-Cookie` lines; `run_worker` moves them into `res.headers` after the dispatcher returns. One call, `web::set_cookie(ctx, name, value, opts)`, works the same in route handlers, page loaders and middleware. Signed sessions are not in v1.

The generator (`cli/gweb.goose`), `client/gwi.js`, `gwi.min.js`, `cli/component.goose` and the templates are not touched.

## Rename mapping

I agree with the mapping. This design uses none of the renamed things except the existing `check_site.py --components` flag, which it leaves alone.

## Template syntax

Template syntax is being redesigned in DESIGN-ADDENDUM-6-SYNTAX.md, which lands before the cookies builder starts. Every template example in this document is written in the current syntax (`{{ expr }}` escaped, `{{#if}}` / `{{#else}}` / `{{/if}}`). The builder must write the demo template in whatever syntax addendum 6 defines; this design does not define or assume any new syntax.

The cookie design does not depend on template syntax. Only these spots contain template text:

- `goose-web/examples/shop/app/cookies/page.html` (the demo page): three escaped expressions (`props.theme` twice, `props.visits` once) and one if/else on `props.returning`. The prototype copy in the scratchpad is in the current syntax and must be converted if addendum 6 changes it.
- The layout example in "Reading cookies": `<body class="{{ web::cookie_or(req, "theme", "light") }}">`. It is an illustration only; no layout is changed.
- The new `## Cookies` section of `goose-web/README.md`, if it shows a template line.

What stays fixed whatever the syntax: the Goose expressions themselves (`web::cookie_or(req, name, fallback)` returns one value so it can be used in any template expression), the rendered HTML that `check_site.py --cookies` checks (`id="theme">light<`, `id="visits">1<`, "First visit", "Welcome back."), and the fact that this design changes nothing in `cli/gweb.goose` template compilation.

One added merge note: if addendum 6 is built as a mechanical conversion of existing templates, `app/cookies/page.html` is a new file from this work and will not be covered by that conversion; the cookies builder converts it.

## What I verified, and what I did not

A working prototype is in `/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-cookies/` (copies of goose-net and goose-web with the change applied, plus the shop demo). Nothing outside it was written and nothing was committed.

Verified:
- `goose check` passes on the changed `web.goose` and `http.goose`.
- `goose-web/test/cookie_test.goose` builds and passes 59 of 59 checks. It covers parsing, every rejection, the exact `Set-Cookie` lines, `apply_cookies`, and the two lifetime shapes: a loader whose `Props` holds slices into `req` while it sets a cookie on `ctx`, and a handler that shrinks `res` while it still uses a cookie view into `req`.
- The shop with the demo below builds with the **unmodified** `gweb` binary and answers correctly over `curl`: two `Set-Cookie` lines on one response, cookies on a 303 redirect, on a 400, on `HEAD`, and three clear lines.
- The existing gate still passes on the changed runtime: `check_site.py --components` prints PASS, and `/products/42` is byte-identical to `baseline/products_42.html`.
- Cost: `Ctx` crossing about 4 KB makes `new_ctx` slower. A microbenchmark gives about 128 ns per request at 2048 bytes (0 up to about 400 bytes, 95 ns at 512, 212 ns at 4096). With `loadgen` at 1 worker, 16 clients, 3 runs each: `/api/health` 224k rps before and after; `/products/42` about 222k before, 218k after (about 2%, near the noise).

Not verified:
- No browser was used; the browser lines below are untested.
- The goose-net test additions and the `check_site.py --cookies` block are specified here but not written.
- The 500 path of `apply_cookies` was tested as a unit only, not over a socket.
- The exact reason for the 4 KB cost step (I measured it, I did not read the compiler).

## Facts from the code that drive the design

- `http::Response.headers` is `u8[..4096]` and `http::set_header` appends a line with no checks. Repeating a header already works: two `Set-Cookie` lines are two appended lines. Exceeding a `u8[..N]` aborts the worker (reference.md, "Exceeding a limited array's capacity aborts"), so every cookie write must check space first.
- `finish`, `apply_redirect`, `plain_not_found` and `http::json_error` never clear `res.headers`, so headers survive every outcome.
- A temporary cannot bind to `const T&` in a default parameter (`the default of parameter opts cannot be passed as const web::CookieOptions&`), so options go by value.
- Struct literal fields must be written in declaration order.
- Goose does not warn when a `bool` result is ignored.
- The stdlib has `base64` but no SHA-256 or HMAC.
- goose-net's HTTP client cannot send request headers or return response headers, so wire tests use raw sockets.

## Reading cookies

```goose
// goose-net/http.goose
fn cookie(req: const Request&, name: const u8[:]) -> const u8[:], bool          // raw view into req

// goose-web/web.goose
fn cookie(req: const http::Request&, name: const u8[:], out: u8[>..]&) -> bool   // percent-decoded, appended
fn cookie_or(req: const http::Request&, name: const u8[:], fallback: const u8[:]) -> const u8[:]   // raw, one value
fn cookie_int(req: const http::Request&, name: const u8[:]) -> i64, bool
```

This mirrors the query helpers: `http::query_param` raw, `web::query` decoded.

Rules for `http::cookie`:
- It reads the **first** `Cookie` header only (`find_header`). RFC 6265 forbids a client from sending two.
- Pairs split on `;`. Name and value are trimmed of ASCII whitespace. The value splits at the first `=`, so `a=b=c` gives `b=c`.
- A pair without `=` is skipped. An empty `name` argument never matches.
- Names match exactly (case-sensitive).
- Duplicates: the first pair wins (browsers send the most specific path first).
- One pair of surrounding double quotes is removed from the value.
- An empty value is present: `"", true`.
- Limits: none added. The head is already capped at 64 KB by goose-net, and the lookup is one scan with no allocation.

`web::cookie` decodes `%XX` only; `+` stays `+`, and a bad escape stays as written. The decoded bytes are untrusted input (they can hold any byte). `web::cookie_or` exists because layouts have no loader and need a single value: `<body class="{{ web::cookie_or(req, "theme", "light") }}">`. It returns the fallback for an absent or empty cookie.

## Setting and clearing cookies

```goose
enum SameSite { Lax, Strict, None }

struct CookieOptions {
    path: u8[..128] = "/",
    domain: u8[..128] = "",             // "" = this host only
    max_age: i64 = -1,                  // seconds; -1 = until the browser closes
    secure: bool = false,               // HTTPS only
    http_only: bool = true,             // hidden from document.cookie
    same_site: SameSite = SameSite.Lax
}

fn set_cookie(ctx: Ctx&, name: const u8[:], value: const u8[:], opts: CookieOptions = CookieOptions { .. }) -> bool
fn clear_cookie(ctx: Ctx&, name: const u8[:], opts: CookieOptions = CookieOptions { .. }) -> bool
fn apply_cookies(ctx: Ctx&, res: http::Response&) -> bool       // run_worker only
```

Use:

```goose
web::set_cookie(ctx, "seen", "1");
web::set_cookie(ctx, "theme", "dark", web::CookieOptions { max_age: 31536000, http_only: false, .. });
web::clear_cookie(ctx, "theme");
```

Defaults: `Path=/`, no `Domain`, session lifetime, not `Secure`, `HttpOnly`, `SameSite=Lax`. `secure` defaults to false because goose-web serves plain HTTP; set it when the site is behind TLS.

Line format, in this fixed order (tests compare exact bytes):

```
Set-Cookie: name=value; Path=/p[; Domain=d][; Max-Age=n][; Expires=Thu, 01 Jan 1970 00:00:00 GMT][; Secure][; HttpOnly]; SameSite=Lax
```

- **Expires:** v1 writes `Max-Age` only. The one `Expires` it writes is the fixed epoch date, added when `max_age` is 0, so a clear also works in clients that ignore `Max-Age`. No date formatting is needed.
- **Name:** 1 to 64 bytes, RFC 6265 token bytes only (letters, digits and ``!#$%&'*+-.^_`|~``).
- **Value:** any bytes. Every byte outside `A-Z a-z 0-9 - . _ ~` is written as `%XX` (upper-case hex). The encoded value may be at most 1024 bytes. Base64url text passes through unchanged.
- **Path:** starts with `/`, bytes 0x21 to 0x7E, no `;`, at most 128.
- **Domain:** letters, digits, `-` and `.` only, at most 128.
- **max_age:** -1 or more. No upper clamp (browsers cap at about 400 days).
- **SameSite=None** always writes `Secure`, because browsers reject it otherwise.
- **Prefixes:** a `__Secure-` name needs `secure`; a `__Host-` name needs `secure`, `path` of `/` and no `domain`. Otherwise false.
- **clear_cookie** is `set_cookie` with an empty value and `max_age` 0. Pass the same `path` and `domain` the cookie was set with.
- **Failure:** returns false and sets nothing. No log line, because a value can be attacker-sized.
- **Limits:** all `Set-Cookie` lines of one response share 2048 bytes. There is no separate count limit; the bytes bound it. One maximum cookie is about 1.4 KB.
- **Same name twice:** both lines are sent in call order; browsers keep the last. No de-duplication.
- **Outcome:** every accepted cookie is sent whatever the outcome: 200, redirect, not found, or a `before` that returned false.

No byte from the caller reaches a header line unchecked, so CR/LF injection through a cookie is not possible.

## How it fits the lifetime rules

`Ctx` stays flat: `set_cookies` is a `u8[..2048]` of finished lines, with no slice or reference. So a loader (which has no `res`) sets a cookie on `ctx` exactly as it sets `ctx.title`, and DESIGN-ADDENDUM-1's risk "loaders cannot set cookies" no longer holds. Reading returns views into `req`, as `http::header` already does; `Props` may keep them.

`run_worker` applies the lines, not the generated `finish`. `ctx` is created in `run_worker`, so one line there covers every route, page and outcome, and the generator does not change:

```goose
static_index = D(req, ctx, res);
if !apply_cookies(ctx, res) { static_index = -1; }      // new line
dev_inject(res, cfg.dev_id);
```

`apply_cookies` appends `ctx.set_cookies` to `res.headers`. When they do not fit beside the headers already there, the reply becomes a bare `500 {"error":"response headers too large"}` with `res.headers` cleared. A cookie is never dropped silently (a dropped logout clear would be a security bug). With 2048 bytes of cookies and a 1024-byte `Location`, about 1000 bytes remain for the app's own headers.

Static files and the trailing-slash redirect run no user code and send no cookies.

## Multiple Set-Cookie headers in goose-net

No change to `Response` or `send_response_with`: `res.headers` is raw lines, and repeating `Set-Cookie` is one line per cookie. goose-net gains two functions:

```goose
fn cookie(req: const Request&, name: const u8[:]) -> const u8[:], bool
fn add_header(res: Response&, name: const u8[:], value: const u8[:]) -> bool
```

`add_header` is the checked `set_header`: false, with `res` unchanged, when the line does not fit, when `name` is empty or holds a control byte, a space or `:`, or when `value` holds CR, LF or NUL. `set_header` stays as it is. goose-web's cookie path does its own checks and does not need `add_header`; it is for goose-net users who set cookies by hand.

## Signed sessions: not in v1

Reason: the stdlib has no SHA-256 or HMAC, so signing means new crypto code (in Goose or in `src/`), a constant-time compare, a secret source and rotation. That is a second review surface, and the shop has no login to prove it on.

What v1 leaves room for:
- Values are opaque and base64url passes unencoded, so `payload.signature` fits in the 1024-byte value.
- `set_cookie` defaults (`HttpOnly`, `SameSite=Lax`) are already right for a session cookie.
- Reserved names for the follow-up: `web::set_signed_cookie(ctx, name, value, opts) -> bool` and `web::signed_cookie(req, name, out) -> bool`, with the secret in `WEB_SECRET` (comma-separated: the first signs, all verify, which gives rotation), read once into `Config`. This is a sketch, not a decision.

## The code

`goose-net/http.goose`:

```goose
fn cookie(req: const Request&, name: const u8[:]) -> const u8[:], bool {
    let line, has = find_header(req.head, "cookie");
    if !has || name.len == 0 { return "", false; }
    each_split(line, ';') { pair =>
        let key, value, eq = split_once(pair, '=');
        if eq && trim(key) == name {
            let v = trim(value);
            if v.len >= 2 && v[0] == '"' && v[v.len - 1] == '"' { return v[1..v.len - 1], true; }
            return v, true;
        }
    };
    return "", false;
}

fn add_header(res: Response&, name: const u8[:], value: const u8[:]) -> bool {
    if name.len == 0 || name.len + value.len + 4 > res.headers.cap - res.headers.len { return false; }
    for c in name { if c <= ' ' || c == ':' || c >= 127 { return false; } }
    for c in value { if c == '\r' || c == '\n' || c == 0 { return false; } }
    format(res.headers, name, ": ", value, "\r\n");
    return true;
}
```

`goose-web/web.goose`, the new section (the enum and struct above go at its top):

```goose
const COOKIE_NAME_MAX = 64;
const COOKIE_VALUE_MAX = 1024;          // after encoding

let COOKIE_NAME_BYTES = byte_set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~");
let COOKIE_PLAIN_BYTES = byte_set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~");
let COOKIE_DOMAIN_BYTES = byte_set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.");
let HEX_UPPER = "0123456789ABCDEF";

fn all_in(s: const u8[:], set: const ByteSet&) -> bool {
    for c in s { if !set.members[c] { return false; } }
    return true;
}

fn cookie(req: const http::Request&, name: const u8[:], out: u8[>..]&) -> bool {
    let v, has = http::cookie(req, name);
    if !has { return false; }
    var i = 0;
    while i < v.len {
        if v[i] == '%' && i + 2 < v.len && ascii::hex_value(v[i + 1]) >= 0 && ascii::hex_value(v[i + 2]) >= 0 {
            out.push((ascii::hex_value(v[i + 1]) * 16 + ascii::hex_value(v[i + 2])) as u8);
            i += 3;
        } else { out.push(v[i]); i += 1; }
    }
    return true;
}

fn cookie_or(req: const http::Request&, name: const u8[:], fallback: const u8[:]) -> const u8[:] {
    let v, has = http::cookie(req, name);
    if has && v.len > 0 { return v; }
    return fallback;
}

fn cookie_int(req: const http::Request&, name: const u8[:]) -> i64, bool {
    let v, has = http::cookie(req, name);
    if !has || v.len == 0 { return 0, false; }
    return parse_int(v);
}

fn set_cookie(ctx: Ctx&, name: const u8[:], value: const u8[:], opts: CookieOptions = CookieOptions { .. }) -> bool {
    let secure = opts.secure || opts.same_site == SameSite.None;
    if name.len == 0 || name.len > COOKIE_NAME_MAX || !all_in(name, COOKIE_NAME_BYTES) { return false; }
    if opts.path.len == 0 || opts.path[0] != '/' { return false; }
    for c in opts.path { if c <= ' ' || c >= 127 || c == ';' { return false; } }
    if !all_in(opts.domain, COOKIE_DOMAIN_BYTES) || opts.max_age < -1 { return false; }
    if starts_with(name, "__Secure-") && !secure { return false; }
    if starts_with(name, "__Host-") && (!secure || opts.path != "/" || opts.domain.len > 0) { return false; }
    var encoded = 0;
    for c in value { encoded += if COOKIE_PLAIN_BYTES.members[c] { 1 } else { 3 }; }
    if encoded > COOKIE_VALUE_MAX { return false; }

    var line: u8[..1536] = "";
    format(line, "Set-Cookie: ", name, "=");
    for c in value {
        if COOKIE_PLAIN_BYTES.members[c] { line.push(c); }
        else { line.push('%'); line.push(HEX_UPPER[c >> 4]); line.push(HEX_UPPER[c & 15]); }
    }
    format(line, "; Path=", opts.path);
    if opts.domain.len > 0 { format(line, "; Domain=", opts.domain); }
    if opts.max_age >= 0 { format(line, "; Max-Age=", opts.max_age); }
    if opts.max_age == 0 { line.append("; Expires=Thu, 01 Jan 1970 00:00:00 GMT"); }
    if secure { line.append("; Secure"); }
    if opts.http_only { line.append("; HttpOnly"); }
    line.append(match opts.same_site { Lax => "; SameSite=Lax", Strict => "; SameSite=Strict", None => "; SameSite=None" });
    line.append("\r\n");
    if line.len > ctx.set_cookies.cap - ctx.set_cookies.len { return false; }
    ctx.set_cookies.append(line);
    return true;
}

fn clear_cookie(ctx: Ctx&, name: const u8[:], opts: CookieOptions = CookieOptions { .. }) -> bool {
    var o = opts;
    o.max_age = 0;
    return set_cookie(ctx, name, "", o);
}

fn apply_cookies(ctx: Ctx&, res: http::Response&) -> bool {
    if ctx.set_cookies.len == 0 { return true; }
    if ctx.set_cookies.len > res.headers.cap - res.headers.len {
        ctx.set_cookies.clear();
        res.headers.clear();
        http::json_error(res, http::Status.InternalServerError, "response headers too large");
        return false;
    }
    res.headers.append(ctx.set_cookies);
    ctx.set_cookies.clear();
    return true;
}
```

The longest possible line is about 1440 bytes, inside the 1536-byte local.

## Where the changes go in web.goose (for the parallel builders)

Exactly four places, nothing else in the file:

1. `struct Ctx`: add the last field `set_cookies: u8[..2048]` after `title`.
2. `new_ctx`: add `set_cookies: ""` to the literal.
3. A new section headed `// ---- cookies (DESIGN-ADDENDUM-5)`, inserted **between the end of `fn split` and the `// ---- responses` header**. All new types and functions live there.
4. `run_worker`: the one line `if !apply_cookies(ctx, res) { static_index = -1; }` directly after `static_index = D(req, ctx, res);`.

The fragments builder should stay out of those four spots; the `responses` section, `html`, the end of the file and everything in `cli/` are free for it. If fragments needs its own `Ctx` field, add it on its own line before `title` so the two edits do not touch the same lines; the `new_ctx` literal is one line, so both builders will edit it and the merge there is a trivial two-field union.

## Shop demo: /cookies

A new page tree; no existing page, layout, CSS or benchmark URL changes (the layout is shared with the benchmark, and `/products/42` must stay byte-identical).

- `app/cookies/middleware.goose`: `before` sets the session cookie `shop_seen=1` (defaults, so `HttpOnly`) when the request does not carry it. Shows middleware setting a cookie.
- `app/cookies/page.goose`: `load` reads `visits` with `web::cookie_int`, adds 1 (starts again at 1 when it is absent, not a number, negative or over 1,000,000), and sets it for a year with `http_only: false`. It reads `theme` with `web::cookie_or` and accepts only `dark`, else `light`. `Props { theme: const u8[:], visits: i64, returning: bool }`. Shows a loader setting a cookie.
- `app/cookies/page.html`: an inline `<style>`, a box with class `theme-{{ props.theme }}`, `<b id="theme">`, `<b id="visits">`, `<p id="seen">` ("Welcome back." or "First visit in this browser session."), and three POST forms with buttons `#dark`, `#light`, `#reset`.
- `app/cookies/theme/[name]/route.goose`: `POST` accepts `dark` or `light` (else 400), sets `theme` for a year with `http_only: false`, and redirects 303 to `/cookies`. Shows a route handler plus a redirect.
- `app/cookies/reset/route.goose`: `POST` clears `theme`, `visits` and `shop_seen`, then redirects 303.

The five files exist, working, under `/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-cookies/goose-web/examples/shop/app/cookies/`.

## File list

Changed:
- `goose-net/http.goose`: `cookie` after `query_param`; `add_header` after `set_header`.
- `goose-net/test/test_net.goose`: the tests below.
- `goose-net/README.md`: two rows in the "Server helpers" table.
- `goose-web/web.goose`: the four places above.
- `goose-web/README.md`: a new `## Cookies` section between `## SQLite` and `## Example`; no other paragraph.
- `goose-bench/shop/check_site.py`: the `--cookies` flag and block.
- `goose-bench/shop/bench_shop.py`: in `check()`, also append `--cookies` for the goose site.

Created:
- `goose-web/test/cookie_test.goose`
- `goose-web/examples/shop/app/cookies/middleware.goose`
- `goose-web/examples/shop/app/cookies/page.goose`
- `goose-web/examples/shop/app/cookies/page.html`
- `goose-web/examples/shop/app/cookies/theme/[name]/route.goose`
- `goose-web/examples/shop/app/cookies/reset/route.goose`

Not touched: `cli/gweb.goose`, `cli/component.goose`, `client/*`, `template.goose`, `static.goose`, `owner.goose`, `test/manual.goose`, `test/components*`, the shop's `layout.html`, `public/` and `components/`.

Shared with the fragments builder, with likely small merges: `web.goose` (see above), `README.md` (separate sections), `check_site.py` and `bench_shop.py` (the flag lines sit next to `--components`). In `check_site.py`, put `COOKIES = "--cookies" in sys.argv[1:]` on the line **before** `COMPONENTS = ...`, and put the cookie block **between the "Static files" block and the "# Components" block**, so a fragments block after Components does not collide.

## Tests

**goose-net (`test/test_net.goose`)**
- `unit_tests`: `http::cookie` on requests built with `http::parse_request`: first duplicate wins; whitespace trimmed; quotes removed; a pair without `=` skipped; empty name never matches; case-sensitive; empty value present; a second `Cookie` header ignored; no `Cookie` header; `a=b=c` gives `b=c`.
- `unit_tests`: `http::add_header`: a normal line; refuses a line that does not fit after a 4000-byte filler and leaves `res.headers` unchanged; refuses CR, LF and NUL in the value; refuses an empty name and a name with `:` or a space.
- `http_worker`: a `/cookie` route that writes `http::cookie(req, "a")` to the body and calls `add_header(res, "Set-Cookie", ...)` twice. A raw-socket test (as `keep_alive_tests` does with `read_responses`) sends `Cookie: a=1; b=2` and checks the body is `1` and the raw response holds exactly two `Set-Cookie:` lines, in order (`count_of`).

**goose-web (`test/cookie_test.goose`)**
Copy the prototype file: 59 checks, no sockets, run with `goose build test/cookie_test.goose && test/cookie_test`. It covers: all the reading rules; decoding (`a%20b%3B%zz+` gives `a b;%zz+`); `cookie_or` on absent and empty; `cookie_int`; the exact default, full-option, `SameSite=None` and clear lines; every rejection (empty, space, `=`, `;`, CRLF and 65-byte names; a 1025-byte value; 342 bytes that encode to 1026; bad path, domain and `max_age`; both prefixes); the 2048-byte limit (a second 1 KB cookie refused, a small one still accepted); `apply_cookies` after an existing header, after a redirect, and the overflow that becomes a bare 500; and the loader and handler lifetime shapes.

**check_site.py `--cookies`** (goose-web only, as `--components` is). The existing `call` returns headers as a dict and loses repeated headers, so the block defines its own helper that returns `r.headers.get_all("Set-Cookie")`. Checks:
1. `GET /cookies` with no cookie: 200; exactly two `Set-Cookie` values, `shop_seen=1; Path=/; HttpOnly; SameSite=Lax` then `visits=1; Path=/; Max-Age=31536000; SameSite=Lax`; body has `id="theme">light<`, `id="visits">1<` and "First visit".
2. `GET /cookies` with `Cookie: visits=4; theme=dark; shop_seen=1`: exactly one `Set-Cookie`, `visits=5; ...`; body has `>dark<`, `>5<`, "Welcome back.".
3. Malformed input, `Cookie: junk; =x; visits=abc; theme="dark"; theme=light`: 200, `visits=1`, theme `dark`.
4. `POST /cookies/theme/dark` with `Cookie: shop_seen=1`: 303, `Location: /cookies`, exactly one `Set-Cookie`, `theme=dark; Path=/; Max-Age=31536000; SameSite=Lax`.
5. `POST /cookies/theme/pink`: 400 and no `Set-Cookie` that starts with `theme=`.
6. `POST /cookies/reset` with `Cookie: shop_seen=1`: 303 and three values, each `NAME=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly; SameSite=Lax`, for `theme`, `visits`, `shop_seen` in that order.
7. `GET /cookies/theme/dark`: 405.
8. `HEAD /cookies`: 200, `Set-Cookie` present, empty body.
9. `/products/42`, `/api/health` and `/css/site.css` send no `Set-Cookie`.
Add `/cookies` to the "bytes per URL" list under the flag. The prototype's `curl` output matches lines 1, 2, 4, 5, 6 and 8.

**Suite commands to run before merge:** `goose-net/test/test_net`, `goose-web/test/cookie_test`, `goose-web/test/owner_test`, `goose-web/test/components.sh`, `gweb test` in the shop, and `check_site.py URL --components --cookies`.

## Browser test lines

1. Open `/cookies` in a fresh profile: theme "light", "Visit number 1", "First visit in this browser session."
2. Reload: "Visit number 2", "Welcome back."
3. In the console, `document.cookie` shows `visits=2` and no `shop_seen`. The storage panel shows `shop_seen` as HttpOnly, session, SameSite Lax, and `visits` with an expiry about a year ahead.
4. Click **Dark**: the page returns to `/cookies` with the dark box and theme "dark"; `document.cookie` now includes `theme=dark`.
5. Click **Light**: the box is light again.
6. Click **Dark**, quit and reopen the browser, open `/cookies`: still dark, the count continues, and the text is "First visit in this browser session." (the session cookie is gone).
7. Click **Forget me**: theme "light", "Visit number 1"; `document.cookie` holds only `visits=1`.
8. Open `/products/42` with the network panel: the response has no `Set-Cookie`, and the request carries the `Cookie` header without changing the page.
9. Open `/components`: the counter and todo components still work.

## Rejected alternatives

- **`set_cookie(res, ...)` for handlers and middleware, pending list only for loaders:** two APIs for one job, and the handler form breaks the "ctx decides, one place applies" rule of addendum 1.
- **Loaders may not set cookies:** rules out the most common case (a visit or session touch on a page view) for no gain.
- **Loaders get `res` back:** addendum 1 removed it because `Props` slices then block every shrink of `res`.
- **A structured pending list (`struct PendingCookie[8]` in `Ctx`):** several times larger than 2048 bytes of finished lines, and formatting still has to happen.
- **Applying in the generated `finish`:** needs a `cli/gweb.goose` change in fragments territory, and `test/manual.goose` would need it too; `run_worker` covers every path with one line.
- **A new file `goose-web/cookie.goose`:** `run_worker` in `web.goose` must call `apply_cookies`, and generated code and user files would need a new import through `gweb.goose`.
- **Reject values with unsafe bytes instead of encoding:** pushes encoding onto every caller; encoding always is what Express and Next do.
- **`url_decode` for cookie values:** it turns `+` into a space, which is wrong for cookies.
- **Full `Expires` support:** needs HTTP date formatting; `Max-Age` is honored by every current browser.
- **De-duplicating a name set twice:** browsers already keep the last line, and it needs line surgery in the buffer.
- **Dropping cookies (or aborting) when headers overflow:** a silent drop can lose a logout; an abort restarts the worker. A 500 is loud and safe.
- **Logging each rejected `set_cookie`:** values can be user-controlled, so it is a log-flood lever.
- **Raising `Response.headers` above 4096:** not needed for v1 limits and changes goose-net for every user.
- **Hoisting `ctx` out of the request loop to avoid the 128 ns:** saves at most about 2% and risks state leaking between requests; revisit only if `bench_shop.py` shows a regression.
- **Signed sessions in v1:** no SHA-256 or HMAC in the stdlib; see above.
- **Theme class on the shared `layout.html`:** changes pages the benchmark compares byte for byte and adds a header scan to every benchmark request.

## Risks

- `Ctx` grows from about 3.6 KB to about 5.7 KB. Measured cost: about 128 ns per request, 0 to 2% at 1 worker. `bench_shop.py` should be rerun after the merge.
- A false from `set_cookie` is easy to ignore, because Goose does not warn about an unused `bool`. The README must say to check it for values that come from users.
- 2048 bytes for all cookies of one response, and 1024 per encoded value, are below the 4096 bytes browsers accept per cookie. A large signed session later may need a bigger buffer, which costs more per request.
- Pages that set cookies carry no `Cache-Control`. Behind a shared cache, a response with `Set-Cookie` could be stored; the app must set `Cache-Control: no-store` in `after` middleware. v1 does not do it automatically.
- A loader runs for `HEAD` too, so the demo's visit count rises on `HEAD`.
- Cookies set before `web::not_found(ctx)` are still sent with the 404. That is the rule, but it may surprise.
- Only the first `Cookie` header is read. A proxy that splits cookies over several headers would hide the later ones.
- `web::cookie_or` and `web::cookie_int` read the raw value. A value that `set_cookie` had to encode reads back encoded through them; use `web::cookie(req, name, out)` for such values.
- `secure` defaults to false. A site behind TLS that forgets to set it sends session cookies that also travel over plain HTTP.
- `http::set_header` still has no checks; only the cookie path and `add_header` are safe against header injection and overflow.
- The browser lines and the `check_site.py` block are specified, not run.
- Both builders edit the `new_ctx` literal line, `check_site.py` and `bench_shop.py`; expect small, mechanical merge conflicts there.
