<!-- Produced by goose-architect on claude-opus-5-5 (medium) -->
# DESIGN-ADDENDUM-13: auth, sessions, secrets, rate limits, CORS, security headers, CSP

**Decision in one paragraph.** goose-web gains a small crypto core in C (`src/crypto.c`: SHA-256, HMAC-SHA-256, PBKDF2-HMAC-SHA-256), so it can sign. Secrets come from `WEB_SECRET` (comma-separated keys, the first signs, all verify), which may live in `.env` files that the server loads at startup in Next.js order. Sessions are **stateless signed cookies**: `gw_session` holds a session id, a user id, an app-defined auth version, issue and expiry times and up to 256 bytes of app data, all under one HMAC. Revocation is the app's job through the auth version, which the app compares with its user row (the CMS loads that row anyway for roles). Passwords use PBKDF2-HMAC-SHA-256 with 600,000 iterations in a self-describing string. Login and logout are plain functions called from a page `fn POST` or a route; a subtree is guarded by one line in `middleware.goose`. Rate limits are a GCRA table in C shared by all workers. CORS is a middleware call. Three safe security headers go on every response by default. CSP with a per-request nonce is opt-in (`WEB_CSP=1`); its `script-src 'self' 'nonce-…'` needs no change to components or `gwi.js`.

## 1. What I read, and the facts this design rests on

Read: `docs/BACKLOG.md`, `ARCHITECTURE.md`, `DESIGN.md` (sections 4 and 5), Addenda 5, 7 and 11, `web.goose`, `csrf.goose`, `form.goose`, `static.goose`, `template.goose` (signatures), `src/sys.c`, `web.build`, `cli/gweb.goose` (`gen_route_fn`, `gen_page_fn`, `gen_dispatch`, `gen_finish`, `gen_main`, the dev command, the `uses_sqlite` and `mentions_csrf` scans, `template_call`), `cli/component.goose` (the `component` emitter), `goose-net/http.goose` and `net.goose` (`Request`, `Response`, `Status`, `peer_address`, `connection_loop`), `goose-net/src/net.c` (`gnet_peer`, `gnet_bytes`). No sibling addendum (12, 14 to 18) existed when I wrote this.

Nothing was compiled: there is no `goose` on PATH or in `$GOOSE`. Every Goose fact below is read from code that already builds, not tried.

- **No SHA-256 or HMAC in the stdlib** (Addenda 5 and 7). A grep of all three repos finds none. Signing needs new code.
- **C sources are cheap to add**: `web.build` lists `c_sources`; `src/sys.c` shows the slice ABI, `typedef struct { uint8_t *data; int64_t len; } gweb_wbytes;` for `u8[:]`. goose-net's `gnet_bytes` shows the const form, `const uint8_t *data`.
- **C can be tested without the Goose compiler** with `cc`. That is the main reason the crypto and the rate table go in C: they are the parts where a bug is a security hole, and they are the parts this machine can test today.
- **`Ctx` is flat and copied per request** (`new_ctx` in `run_worker`). Addendum 5 measured about 128 ns at 2 KB of growth and a step near 4 KB; `Ctx` is about 5.7 KB now.
- **`Config` is passed by value to each worker thread** (`thread_spawn(supervisor, i, server, ..., cfg)`), so anything in `Config` is safe to read from every worker without globals.
- **Middleware is `fn before(req, ctx, res) -> bool`**; false ends the request, and the dispatch leaf still calls `finish`, so `web::redirect(ctx, ...)` inside `before` works.
- **Generated route functions run `csrf_ok` first, then `before`, then the method match**, and `OPTIONS` passes `csrf_ok`. So a `before` sees CORS preflights. Page functions answer `OPTIONS` before middleware.
- **The peer address**: `lp.next(raw)` returns `conn: net::Socket`; `net::peer_address(conn)` makes a `getpeername` call and allocates. It must stay off the hot path.
- **Time**: `time()` (f64 seconds since the epoch) is used in `cli/gweb.goose` and the scaffold.
- **Env**: `env(name, out) -> bool` exists. There is no `setenv`.
- **Script tags gweb emits are all external**: `GW_SCRIPT` is `<script type="module" src="/_gw/gwi.js">`, and a component emits `<script type="application/json">` (a data block, never executed) plus `<script type="module" src="/_gw/Name.js">`. The only inline script gweb writes is `dev_inject`'s.
- **`http::Status` has no 429.** `Status.Other { code: 429 }` is sent as `429 Unknown`.
- **`csrf_cookie_name` already trusts `X-Forwarded-Proto`** without a proxy setting (Addendum 7, D3).

## 2. Decisions

### D1. Crypto core in C

`src/crypto.c`, a portable implementation from FIPS 180-4, RFC 2104 and RFC 8018:

```c
typedef struct { const uint8_t *data; int64_t len; } gweb_bytes;
// gweb_wbytes is already in sys.c; crypto.c declares its own copy.
int32_t gweb_sha256(gweb_wbytes out32, gweb_bytes msg);                         // 1 on success; out.len must be 32
int32_t gweb_hmac_sha256(gweb_wbytes out32, gweb_bytes key, gweb_bytes msg);    // any key length
int32_t gweb_pbkdf2_sha256(gweb_wbytes out, gweb_bytes pw, gweb_bytes salt, int64_t iter); // out.len 1..64, iter 1..10,000,000
```

Goose side, `crypto.goose` (`namespace web;`, imports `std` and `web`):

```goose
fn sha256(out: u8[..32]&, msg: const u8[:])
fn hmac_sha256(out: u8[..32]&, key: const u8[:], msg: const u8[:])
fn b64url(out: u8[>..]&, data: const u8[:])                      // no padding
fn b64url_decode(out: u8[>..]&, s: const u8[:]) -> bool          // false on any byte outside the alphabet or a bad length
fn bytes_equal(a: const u8[:], b: const u8[:]) -> bool           // no early exit; lengths may differ (false)
fn random_bytes(out: u8[:]) -> bool                              // getentropy, at most 256
```

`b64url` and `random_bytes` are also needed by `web.goose` itself (D7 nonce, D2 dev secret), and `web.goose` cannot import a sibling that imports `web`. So **`b64url` and the `c_entropy` extern move into `web.goose`**; `csrf.goose` drops its own `extern fn c_entropy` line (same namespace, so it still sees it) and `crypto.goose` holds the rest.

- **Reason for C.** Speed matters for PBKDF2 (600,000 HMACs per login), Goose's integer overflow rules for `u32` rotate-and-add are not something I could check here, and the C can be tested now against published vectors.
- **Rejected:** CommonCrypto (macOS only), OpenSSL or libsodium (a link dependency the Linux and Docker work would inherit), SHA-256 in Goose (unverifiable here, slower).

### D2. Config, `.env` files and secrets

**Environment name.** `GWEB_ENV` if set; otherwise `development` when `--dev-id` is in the arguments (only `gweb dev` passes it), else `production`. `config_from_args` sets `GWEB_ENV` to that value (no overwrite) before loading files, and `web::environment(out: u8[>..]&)` reads it back.

**`.env` loading.** `config_from_args` calls `load_env_files(envname)` first, before it reads `PORT` and `WEB_WORKERS`. Files are read from the working directory in this order, and **the first to set a name wins; the real environment beats all files** (Next.js order):

1. `.env.<env>.local`
2. `.env.local` (skipped when the env is `test`)
3. `.env.<env>`
4. `.env`

Values are set with a new C `gweb_setenv(name, value)` (no overwrite) in `src/sys.c`, in `main` before any thread starts. Workers then read them with `env()`; nothing writes the environment after startup.

Line rules: blank lines and lines whose first non-space byte is `#` are skipped; an optional `export ` prefix; `NAME=VALUE` with `NAME` matching `[A-Za-z_][A-Za-z0-9_]*`; the value is trimmed, and one pair of matching `"` or `'` quotes is removed. No escapes, no interpolation, no inline comments after unquoted values (a `#` is part of the value). Any other line is a startup error, `.env.local:7: error: expected NAME=value`, and exit 2. A missing file is skipped.

**Typed app config.** Apps read typed values with helpers in `web.goose`:

```goose
fn env_str(name: const u8[:], out: u8[>..]&) -> bool        // false when unset
fn env_int(name: const u8[:], fallback: i64) -> i64          // fallback when unset or not an integer
fn env_bool(name: const u8[:], fallback: bool) -> bool       // 1/true/yes/on and 0/false/no/off, case-insensitive
fn env_required(name: const u8[:]) -> bool                   // prints "config: NAME is not set" to stderr when unset
```

An optional `app/config.goose` with `fn check() -> bool` is called by the generated `main` right after `config_from_args`, before `listen`; false exits with status 2. The pattern for typed config is an app struct built from these helpers in `lib/`; the README shows it. Per environment differences live in the `.env.<env>` files.

**Secrets.** `WEB_SECRET` holds 1 to 4 keys, comma-separated, each 32 to 64 bytes (64 hex digits from `openssl rand -hex 32` fits). The first signs; all verify, which gives rotation. `Config` gains:

```goose
struct Keys { n: i64 = 0, k: u8[..64][4] = [""; 4] }
struct AuthConfig { keys: Keys = Keys { .. }, idle: i64 = 86400, max: i64 = 2592000, trust_proxy: bool = false }
// Config gains:  auth: AuthConfig, security_headers: bool, hsts: i64, csp: i64   (csp: 0 off, 1 on, 2 report-only)
```

- A malformed `WEB_SECRET` (a key under 32 or over 64 bytes, more than 4, an empty item) is a startup error and exit 2. The message never prints a key.
- **Missing secret in development:** `config_from_args` reads `.gooseweb.dev/secret`, or makes it (32 random bytes as 64 hex digits, mode 0600 is not settable from Goose, so it is a dev-only file), so sessions survive `gweb dev` rebuilds.
- **Missing secret in production:** gweb scans app and lib code and templates for `web::login`, `web::session`, `web::signed_cookie` and `web::set_signed_cookie` (the same text-scan idea as `mentions_csrf`). When any is found, the generated `main` emits, after `config_from_args`: `if cfg.auth.keys.n == 0 { print("goose-web: set WEB_SECRET (32 to 64 bytes; openssl rand -hex 32)"); exit(2); }`. An app that uses none of them starts as before.
- `WEB_SESSION_IDLE` and `WEB_SESSION_MAX` (seconds) set `idle` and `max`; `WEB_TRUST_PROXY=1` sets `trust_proxy`.

`Ctx` gains `auth: AuthConfig` (about 290 bytes), copied from `cfg.auth` in `run_worker`. That is the only way handlers reach keys without globals.

Rejected:
- **Module-level `var` keys set in `main`.** Whether Goose allows a worker thread to read a module `var` written before spawn is not something I could check. `Config` by value is known to work.
- **A TOML or JSON config file with reflection-driven typing.** Needs reflection Goose does not have; env plus `.env` is what Next.js and twelve-factor apps use.
- **`gweb dev` exporting `WEB_SECRET` to the child.** It would beat a `.env.local` value, because the real environment wins.

### D3. Signed cookies

```goose
fn set_signed_cookie(ctx: Ctx&, name: const u8[:], value: const u8[:], opts: CookieOptions = CookieOptions { .. }) -> bool
fn signed_cookie(req: const http::Request&, ctx: const Ctx&, name: const u8[:], out: u8[>..]&) -> bool
```

- Wire value: `b64url(value) "." b64url(mac)` where `mac = HMAC-SHA-256(K, name "=" b64url(value))` and `K = HMAC-SHA-256(master, "goose-web signed cookie v1")`. The name is under the MAC, so a value cannot be moved to another cookie. The derived key keeps the raw secret out of every MAC.
- Verify tries each key in order; `bytes_equal` compares the MAC.
- `value` is at most 700 bytes (encoded about 934 plus the 44-byte MAC, under the 1024 cookie limit). False when no key is loaded.
- **Signed, not encrypted.** The user can read the value. The README says so.

### D4. Sessions: a stateless signed cookie

```goose
enum SessionState { Unread, Absent, Valid }
struct Session { state: SessionState = SessionState.Unread, sid: u8[..22] = "", uid: i64 = 0, ver: i64 = 0,
                 iat: i64 = 0, exp: i64 = 0, remember: bool = false, data: u8[..256] = "" }
// Ctx gains: session: Session = Session { .. }
```

**Cookie.** Name `gw_session`, or `__Host-gw_session` (with `Secure`) when `X-Forwarded-Proto` is `https` (the same rule as `csrf_cookie_name`, so under HTTPS a plain `gw_session` is ignored). `Path=/; HttpOnly; SameSite=Lax`. `Max-Age=<max>` only when `remember`; otherwise a browser-session cookie.

Value, fields joined by `.`:

```
1 . sid . uid . ver . iat . exp . r . data . mac
```

`1` is the format version; `sid` 22 b64url bytes (16 random); `uid`, `ver`, `iat`, `exp` decimal i64 (`iat` the login time, `exp` the idle deadline, both Unix seconds); `r` is `0` or `1`; `data` is b64url; `mac` is b64url of `HMAC-SHA-256(K, "gw_session=" + everything before the last ".")` with `K = HMAC-SHA-256(master, "goose-web session v1")`. The longest value is about 520 bytes.

**Loading is lazy and explicit.** Nothing reads the session unless the app asks, so pages that do not use it pay nothing (the benchmark pages stay the same).

```goose
fn session(req: const http::Request&, ctx: Ctx&) -> bool       // true when a valid session is loaded; cached in ctx
fn user_id(ctx: const Ctx&) -> i64                              // 0 unless ctx.session.state is Valid (template.goose, for templates)
fn logged_in(ctx: const Ctx&) -> bool                           // template.goose
```

`session` is Valid only when: the version is `1`, every field parses, the MAC verifies under some key, `now < exp`, and `now < iat + max`. Anything else is Absent, with no error and no cookie change.

**Sliding refresh.** When a valid session has used more than half its idle window (`exp - now < idle / 2`), `session` re-issues the cookie with `exp = min(now + idle, iat + max)`, the same `sid`, through `set_cookie` into `ctx.set_cookies`. `session` has no `res`, so it cannot add `no_store`; see Risks. A refresh that does not fit the cookie buffer is skipped silently (the old cookie still works until `exp`).

**Login, logout, guards.**

```goose
struct LoginOptions { remember: bool = false, data: u8[..256] = "" }
fn login(req: const http::Request&, ctx: Ctx&, res: http::Response&, uid: i64, ver: i64,
         opts: LoginOptions = LoginOptions { .. }) -> bool                      // false after writing a 500
fn logout(req: const http::Request&, ctx: Ctx&)
fn session_set_data(req: const http::Request&, ctx: Ctx&, data: const u8[:]) -> bool   // re-signs; false when no session
fn require_login(req: const http::Request&, ctx: Ctx&, res: http::Response&, login_path: const u8[:]) -> bool
fn require_login_api(req: const http::Request&, ctx: Ctx&, res: http::Response&) -> bool
fn safe_next(next: const u8[:], fallback: const u8[:]) -> const u8[:]
```

- `login` makes a fresh `sid` (never reuses one: no fixation), sets the cookie, and **rotates the CSRF token**: it clears the CSRF cookie and `ctx.csrf`, so the next page makes a new token. A token planted before login (for example by a sibling subdomain on plain HTTP) dies at login. False with `500 {"error":"WEB_SECRET is not set"}` when no key is loaded, or `"session unavailable"` when entropy or the cookie buffer fails. It also calls `no_store(res)`.
- `logout` clears the session cookie and the CSRF cookie and sets `ctx.session` to Absent. It must be called from a POST (CSRF-checked); the README shows a form, never a GET link.
- `require_login`: true when `session(req, ctx)`. Otherwise, for GET and HEAD, a 303 to `login_path?next=<percent-encoded path and query>` through `web::redirect`; for other methods, a 303 to `login_path` with no `next`. Returns false. A gw-target fragment request then gets a redirect whose reply has no `GW-Fragment` echo, so `gwi.js` navigates to the login page (Addendum 4 behaviour).
- `require_login_api`: false after writing `401 {"error":"login required"}`.
- `safe_next` returns `next` only when it starts with `/`, its second byte is not `/` or `\`, it has no byte below 0x21 or 0x7F, and it is at most 512 bytes; else `fallback`. No open redirect.

**Revocation.** `ver` is the app's: the CMS keeps `users.session_version`, compares it after `require_login`, and bumps it on password change, role change, disable or "log out everywhere". A guard:

```goose
// app/admin/middleware.goose
import web.session;
fn before(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) -> bool {
    if !web::require_login(req, ctx, res, "/login") { return false; }
    let u, ok = users::by_id(ctx.session.uid);
    if !ok || u.session_version != ctx.session.ver {
        web::logout(req, ctx);
        web::redirect(ctx, "/login", 303);
        return false;
    }
    return true;
}
```

Rejected:
- **A server-side session store in goose-web** (owner thread or SQLite). The owner thread exists only with `app/state.goose` and loses everything on restart; SQLite is an optional package that goose-web's runtime cannot import unconditionally. A store also costs a lookup on every request, which the per-user version already gives the CMS for free (it loads the user row anyway). An app that wants per-session revocation can keep a `sessions(sid, revoked)` table and check `ctx.session.sid`; the sid is in the cookie for exactly that.
- **Encrypted cookies (AES-GCM).** More C crypto for data the user may see anyway; nothing secret belongs in a session.
- **Loading the session in `run_worker` for every request.** A header scan and an HMAC on every benchmark request, for pages that never read it.
- **JWT.** Same idea with algorithm agility and a larger value; no gain.
- **Login through a framework route (`/__gweb/login`).** Apps own their user table, form and messages; a function is enough.

### D5. Passwords

```goose
const PBKDF2_ITER = 600000;
fn password_hash(out: u8[>..]&, password: const u8[:]) -> bool                 // false when entropy fails
fn password_hash_iter(out: u8[>..]&, password: const u8[:], iter: i64) -> bool  // tests, and raising the cost later
fn password_verify(stored: const u8[:], password: const u8[:]) -> bool
fn password_needs_rehash(stored: const u8[:]) -> bool                           // iterations below PBKDF2_ITER
```

- Format: `$pbkdf2-sha256$600000$<salt b64url, 16 bytes>$<hash b64url, 32 bytes>` (78 bytes). Self-describing, so the cost can rise later and `password_needs_rehash` tells the login to re-store.
- `password_verify` with `stored == ""` hashes against a fixed dummy and returns false, so "no such user" costs the same time as "wrong password". The app passes `""` for an unknown user. A malformed `stored`, or iterations above 10,000,000, is false (after the dummy hash).
- Passwords are bytes as sent; no Unicode normalization. Over 1024 bytes is false (and `password_hash` refuses it).
- Cost: one login holds a worker for roughly 0.2 to 0.5 s (estimate, not measured). With 4 workers, a login flood is a denial of service; D6 rate limits are the defence, and the README puts `rate_limit` in the login example.

Rejected:
- **Argon2id.** The best choice on paper (memory-hard), but BLAKE2b plus Argon2 is far more C, and 19 MB per hash times 4 workers. Open question 1.
- **bcrypt.** 72-byte password limit and Blowfish code; no better than PBKDF2 at this iteration count.
- **scrypt.** Memory-hard, but more code than PBKDF2 for a first version.

### D6. Rate limiting

C (`src/rate.c`): one process-wide table of 8,192 slots `{ uint64_t key; int64_t tat_ms; }` behind a `pthread_mutex_t`, shared by all workers. GCRA: emission interval `T = period_ms / limit`; `new_tat = max(tat, now) + T`; refused when `new_tat - now > period_ms`, with the retry time `new_tat - now - period_ms`. Up to 8 linear probes from the key's slot: a matching key, else an empty or expired slot (`tat <= now`), else the slot with the smallest `tat` is evicted.

```c
int64_t gweb_rate_take(gweb_bytes key, int64_t now_ms, int64_t period_ms, int64_t limit); // 0 = allowed, else ms to wait
void gweb_rate_reset(void);                                                               // tests only
```

C hashes the key (FNV-1a 64), so Goose does no wrapping arithmetic.

```goose
fn client_ip(req: const http::Request&, ctx: const Ctx&, out: u8[>..]&)
fn rate_limit(req: const http::Request&, ctx: Ctx&, res: http::Response&, name: const u8[:], limit: i64, period_s: i64) -> bool
fn rate_limit_key(ctx: Ctx&, res: http::Response&, name: const u8[:], key: const u8[:], limit: i64, period_s: i64) -> bool
```

- The key is `name "\0" client_ip` (or `name "\0" key`). False after writing `429` (`Status.Other { code: 429 }`), `Retry-After: <seconds, rounded up>`, and the body `too many requests; try again in N seconds\n`.
- `client_ip`: with `ctx.auth.trust_proxy`, the last comma item of `X-Forwarded-For`, trimmed, when present; otherwise the peer address from `net::peer_address` with the port removed (`[::1]:5` gives `::1`). `Ctx` gains `conn_fd: i32 = -1`, set in `run_worker` from `conn.fd`, so the `getpeername` call happens only when a limit is checked.
- Use in a login POST: `rate_limit(req, ctx, res, "login", 10, 60)` and `rate_limit_key(ctx, res, "login-user", username, 5, 60)`.

Rejected:
- **Per-worker tables.** A client's new connections spread over workers, so the limit becomes `limit × workers`.
- **The owner thread.** Exists only with `app/state.goose`, and a round trip costs more than a mutex.
- **Fixed windows.** Allow twice the limit across a window edge.

Known limit: an attacker with many addresses can evict entries. The table is a speed bump, not a firewall.

### D7. Security headers and CSP

**Default headers.** After `apply_cookies`, `run_worker` appends this fixed block to every response that went through the dispatcher (pages, routes, static files, 404s), unless `cfg.security_headers` is false (`WEB_SECURITY_HEADERS=0`) or the handler set `ctx.default_headers = false`:

```
X-Content-Type-Options: nosniff
Referrer-Policy: strict-origin-when-cross-origin
X-Frame-Options: SAMEORIGIN
```

`Strict-Transport-Security: max-age=<hsts>; includeSubDomains` is added when `WEB_HSTS=<seconds>` is above 0 (browsers ignore it over plain HTTP). If the block does not fit beside the headers, the reply becomes the same bare 500 as `apply_cookies`.

- `SAMEORIGIN`, not `DENY`, because the CMS page builder will preview pages in a same-origin iframe.
- No `Cross-Origin-Opener-Policy` by default: it breaks OAuth and payment popups that use `window.opener`.
- `Ctx` gains `default_headers: bool = true`. A handler that wants another frame rule sets it false and writes its own.

**CSP.** Off by default, because it breaks inline `<script>` and `onclick=` in existing templates. `WEB_CSP=1` (or `--csp`) turns it on for every HTML response; `WEB_CSP=report-only` sends `Content-Security-Policy-Report-Only` instead, for migration. A subtree can turn it on alone with `web::csp_begin(ctx)` in `before`.

- When on, `run_worker` makes the nonce before the dispatcher: 16 random bytes as 22 b64url bytes in `ctx.nonce: u8[..24]`. `csp_begin` does the same when `ctx.nonce` is empty.
- After the dispatcher, when `ctx.nonce` is not empty and the content type starts with `text/html`, it adds:
  `Content-Security-Policy: script-src 'self' 'nonce-N'; object-src 'none'; base-uri 'self'; frame-ancestors 'self'`
- `'self'` covers `/_gw/gwi.js` and every `/_gw/Name.js`; JSON data blocks are not executed. So **components, the compiler and `gwi.js` do not change.**
- `dev_inject` takes the nonce and writes `<script nonce="N">`.
- Templates: `<script nonce="{web::nonce(ctx)}">` (new `fn nonce(ctx: const Ctx&) -> const u8[:]` in `template.goose`).
- No `style-src`: inline `<style>` and `style=` stay allowed. An app adds a stricter policy with its own second CSP header; browsers enforce both.

Rejected:
- **`'strict-dynamic'`.** It disables `'self'`, so every component script tag would need the nonce, which means passing `ctx` into `Name::component` in the component compiler (the reactivity architect's file).
- **CSP on by default.** Breaks existing apps silently in the browser.
- **Hashes instead of nonces.** gweb does not know the user's inline scripts at build time, and the dev script changes per build.

### D8. CORS

```goose
struct CorsOptions { origins: u8[..1024] = "", methods: u8[..128] = "GET, POST, PUT, PATCH, DELETE",
                     headers: u8[..256] = "Content-Type, X-CSRF-Token", credentials: bool = false, max_age: i64 = 600 }
fn cors(req: const http::Request&, ctx: Ctx&, res: http::Response&, opts: CorsOptions) -> bool
```

Called in a route's `before`. `origins` is a comma list of exact origins (`https://a.example`), or `*`.

- No `Origin` header: true, nothing added.
- Allowed origin: `Access-Control-Allow-Origin` echoes it (or `*` when `origins` is `*` and not `credentials`), plus `Vary: Origin` and, with `credentials`, `Access-Control-Allow-Credentials: true`.
- Preflight (`OPTIONS` with `Access-Control-Request-Method`): allowed gives `204` with the origin headers, `Access-Control-Allow-Methods`, `Access-Control-Allow-Headers` and `Access-Control-Max-Age`, and returns false (final). Not allowed gives `403 CORS origin not allowed\n` and false.
- Actual request from a disallowed origin: true with no CORS headers (the browser hides the reply), **except** an unsafe method with `credentials`: `403` and false. A cross-site urlencoded form POST needs no preflight, so without this rule a credentialed CORS route with `const CSRF = false;` would be open to CSRF from any site.
- `origins: "*"` with `credentials: true` matches nothing (browsers refuse it anyway); the README says so.
- Unsafe cross-origin requests also need `const CSRF = false;` on the route, because `csrf_ok` refuses `Sec-Fetch-Site: cross-site`. The README states the rule from Addendum 7: such a route must not trust cookies, unless `credentials` and the origin list are both deliberate.
- Pages get no CORS: their generated code answers `OPTIONS` before middleware.

### D9. Middleware shape

No new hook. Everything is a call in `before` (or in a handler), in the order the app writes:

```goose
// app/api/middleware.goose
import web.cors;
fn before(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) -> bool {
    return web::cors(req, ctx, res, web::CorsOptions { origins: "https://app.example", .. });
}
```

- The framework-wide pieces that need no app code (`.env`, keys, default headers, CSP nonce) are in `config_from_args` and `run_worker`.
- **Rejected: a declarative `app/security.goose` with constants** (`const CORS_ORIGINS = ...`). It needs another generator scan per setting and still cannot express per-user logic; plain calls are already typed and ordered.

### D10. New files and imports

- `crypto.goose`, `session.goose` (signed cookies, sessions, login, passwords), `rate.goose`, `cors.goose`; all `namespace web;`, each importing `std`, `net`, `net.http`, `web` and siblings with `import .name;` (Addendum 7, the `.form` finding).
- `gen_main` adds `import web.crypto;`, `import web.session;`, `import web.rate;`, `import web.cors;` on the line after `import web.csrf;`. User files import what they call (`import web.session;`).
- `web.build`: `c_sources = ["src/owner.c", "src/sys.c", "src/crypto.c", "src/rate.c"];`.

### D11. Edit regions in shared files (for parallel architects)

- **`web.goose`:** (a) `Ctx`: new fields on their own lines **after** `set_cookies` (keep the `csrf` line untouched); all have defaults, so `new_ctx` does not change. (b) `Config` and `default_config`: new fields at the end. (c) New section `// ---- secrets and env (DESIGN-ADDENDUM-13)` directly before `// ---- the worker loop`. (d) `run_worker`: three lines next to the existing `apply_cookies` line, and the `dev_inject` call gains the nonce argument. Operations work (graceful shutdown, logging) will also touch `run_worker`; keep hunks small.
- **`template.goose`:** three functions appended at the end (`nonce`, `user_id`, `logged_in`). Forms-errors may also append; a trivial merge.
- **`cli/gweb.goose`:** `uses_keys` beside `uses_sqlite`, the scan where `uses_sqlite` is set, `app/config.goose` detection beside `app/state.goose`, and `gen_main`'s import line and two emitted checks. Nothing in templates, dispatch or components.
- **`csrf.goose`:** one line removed (the `extern`).
- **Untouched:** `client/*`, `cli/component.goose`, `cli/tscan.goose`, goose-net, goose-sqlite.

## 3. Open questions for the user

1. **Password hash.** PBKDF2-SHA-256 at 600,000 iterations (default, small and portable) or Argon2id (stronger against GPUs, much more C, about 19 MB per hash)? The hash string is self-describing, so a later switch re-hashes at login.
2. **Session store.** Stateless signed cookies with a per-user version (default) or a server-side table so a single session can be revoked at once? The CMS can add the table later on `ctx.session.sid`.
3. **Lifetimes.** Idle 24 hours, absolute 30 days (default). A CMS admin may want shorter.
4. **Default headers.** On for every response (default). They add about 110 bytes per response.
5. **429 reason phrase.** Add `TooManyRequests` to goose-net's `Status` (a goose-net release), or keep `429 Unknown` (default for now)?
6. **A page `fn POST` cannot end the reply.** Found in step 6: `gen_page_fn` renders whenever `ctx.outcome` is `Continue`, so a 429 or 500 written by `rate_limit` or `login` in a page POST gets the page appended. Default: login forms post to a `route.goose` (the fixture does). A fix is an `Outcome.Done` variant that `gen_page_reply` and `finish` skip; that touches the forms-errors architect's ground, so I left it.
7. **Per-user login limit.** `rate_limit_key` on the username lets anyone lock a user out for a minute with 5 bad tries. Default: keep it in the example (it caps guessing across many addresses); an app can drop it.
8. **Proxy trust.** `X-Forwarded-For` is used only with `WEB_TRUST_PROXY=1`, but the CSRF and session cookie names already trust `X-Forwarded-Proto` unconditionally. Should that also move behind `WEB_TRUST_PROXY`? Default: leave CSRF as Addendum 7 shipped it.

## 4. Build plan

Each step: commit locally, never push, edit only inside the worktree. With no Goose compiler, Goose tests are written but not run; C tests run with `cc`.

### Step 1. Crypto core

- Files: `src/crypto.c` (new), `web.build`, `crypto.goose` (new), `web.goose` (move `c_entropy` extern, add `b64url`; one small hunk in the cookies section's neighbourhood or the new section), `csrf.goose` (drop the extern), `test/crypto_test.c` (new), `test/crypto_test.goose` (new).
- Tests:
  - `test/crypto_test.c` links `src/crypto.c`: SHA-256 of `""`, `"abc"`, the 448-bit NIST message and one million `a`; HMAC-SHA-256 RFC 4231 cases 1 to 7 (including the 131-byte key); PBKDF2-HMAC-SHA-256 vectors (`password`/`salt` at 1, 2 and 4096 iterations, 32-byte output; and RFC 7914 section 11's `passwd`/`salt`, 1 iteration, 64 bytes); refusals (`out.len` 31, iter 0, iter above 10,000,000). Run: `cc -O2 -o /tmp/ct test/crypto_test.c src/crypto.c && /tmp/ct` prints `N of N`.
  - `test/crypto_test.goose`: the same SHA and HMAC vectors through the Goose wrappers; `b64url` of `""`, `f`, `fo`, `foo`, `foob`, `fooba`, `foobar` and bytes 0xfb 0xff; decode round trips; decode refusals (`=`, `+`, `/`, length 1 mod 4); `bytes_equal` on equal, different, and different lengths; `random_bytes` gives two different 16-byte values.
- Done: the C test passes here; the Goose test is written and listed as untested if no compiler.

### Step 2. Env files, secrets, config

- Files: `web.goose` (section (c), `Config`, `AuthConfig`, `Keys`, `config_from_args`, `Ctx.auth`, the `run_worker` copy), `src/sys.c` (`gweb_setenv`), `cli/gweb.goose` (`uses_keys` scan, `app/config.goose` `check`, the two emitted `main` checks), `test/env_test.goose` (new), `test/env_test.c` (new, for `gweb_setenv`), `.gitignore` of the `gweb new` scaffold (`.env*.local`).
- Tests (`env_test.goose`, a temp dir with written `.env` files): order and precedence (real env beats all; `.env.production.local` beats `.env.local` beats `.env.production` beats `.env`); `.env.local` skipped for `test`; quotes, `export`, comments, blank lines, `#` inside an unquoted value; the parse error text and line; `env_int`, `env_bool`, `env_str`, `env_required`; `WEB_SECRET` parsing (1 and 3 keys; refusals for 31 and 65 bytes, 5 keys, an empty item); `environment()` defaults. A parse function that returns an error string is tested directly, so the test never calls `exit`.
- Done: C setenv test runs here; Goose test written.

### Step 3. Signed cookies, sessions, login, passwords

- Files: `session.goose` (new), `web.goose` (`Ctx.session`), `template.goose` (`user_id`, `logged_in`), `cli/gweb.goose` (`gen_main` imports), `test/session_test.goose` (new).
- Tests (no sockets, a fixed key in `ctx.auth`, a clock argument: the session functions take `now` from a `fn now_s() -> i64` that a test can bypass through internal functions that take `now`):
  - signed cookies: round trip; a flipped value byte, a flipped MAC byte, another cookie name, no key loaded: all refused; the second key verifies, a removed key does not.
  - session: login writes exactly one session `Set-Cookie` line with the D4 attributes and clears the CSRF cookie; parsing back gives the same uid, ver, data; expired by `exp`; expired by `iat + max`; a tampered field; a wrong version digit; the plain name refused under HTTPS; refresh happens past half the idle window and not before, and never beyond `iat + max`; `remember` writes `Max-Age`.
  - `require_login` redirect targets with and without a query, for POST; `require_login_api` 401 body; `safe_next` cases (`/a`, `//evil`, `/\evil`, `https://x`, a control byte, 513 bytes, `""`).
  - passwords at 1,000 iterations: hash then verify; wrong password; `""` stored is false; malformed strings; `needs_rehash` true at 1,000 and false at 600,000 (only parsed, not computed); one real 600,000-iteration hash, timed and printed.
- Done: written; untested if no compiler.

### Step 4. Rate limiting and client address

- Files: `src/rate.c` (new), `web.build`, `rate.goose` (new), `web.goose` (`Ctx.conn_fd`, `run_worker` sets it), `test/rate_test.c` (new), `test/rate_test.goose` (new).
- Tests: C: limit 3 per 1,000 ms allows 3 and refuses the 4th with the right wait; allows again after `T`; distinct keys are independent; eviction when 9 keys share a probe run; 8 threads hammering one key never allow more than the limit (pthread). Goose: `client_ip` with and without `trust_proxy` and `X-Forwarded-For: a, b`; the 429 status, `Retry-After` and body.
- Done: C test passes here; Goose test written.

### Step 5. Security headers, CSP, CORS

- Files: `web.goose` (`Config.security_headers/hsts/csp`, flags and env, `Ctx.default_headers`, `Ctx.nonce`, `apply_security(ctx, res, cfg) -> bool`, `run_worker` lines, `dev_inject` nonce), `cors.goose` (new), `template.goose` (`nonce`), `test/security_test.goose` (new).
- Tests: the exact default block; opt-out by config and by `ctx.default_headers`; HSTS line; overflow becomes the 500; CSP header only for `text/html` and only with a nonce; report-only header name; nonce is 22 b64url bytes and differs per call; `dev_inject` output contains `nonce="N"`. CORS: no Origin; allowed and disallowed origins; preflight 204 headers exact; preflight refused 403; `*` without and with credentials; credentialed unsafe request from a disallowed origin is 403; `Vary: Origin`.
- Done: written; untested if no compiler.

### Step 6. Fixture site, wire suite, docs

- Files: `test/auth/site/app/...` (a login page with `fn POST` that uses `rate_limit`, `password_verify` against a hard-coded test hash at 1,000 iterations, `login`, `safe_next`; `logout/route.goose` POST; `admin/middleware.goose` with `require_login`; `admin/page.html` showing `web::user_id(ctx)`; `api/middleware.goose` with `cors`; `.env` and `.env.development` fixtures with a test-only `WEB_SECRET`), `test/auth.sh` (new, in the style of `fragments.sh`), `test/release_check.sh` (run the new Goose tests and `auth.sh`), `README.md` (sections `## Config and secrets`, `## Sessions and login`, `## Rate limits`, `## CORS`, `## Security headers and CSP`, placed after `## CSRF`), `CHANGELOG.md` (an unreleased section), `docs/ARCHITECTURE.md` (one bullet in section 3 and rows in section 6).
- `auth.sh` checks: `/admin` without a cookie gives 303 to `/login?next=%2Fadmin`; a wrong password gives the same page and message as an unknown user; the 11th login POST in a minute gives 429 with `Retry-After`; a good login gives 303 to `next`, a `gw_session` line and a CSRF clear line; `/admin` with that cookie shows the uid; a tampered cookie redirects; logout clears it; `/admin` has the three default headers; with `WEB_CSP=1` the HTML has a CSP header with a nonce and the dev script carries it; CORS preflight from an allowed and a disallowed origin; startup without `WEB_SECRET` in production exits 2 with the message.
- Done: written; untested if no compiler.

## 5. Risks

- **Nothing in Goose was compiled.** The extern ABI for `const u8[:]`, `import .name` chains of four siblings, struct defaults inside `Ctx`, and `u8[..64][4]` literals are read from working code, not tried.
- **`Ctx` grows by about 900 bytes** (auth 290, session 330, nonce 24, small fields). Addendum 5 saw a cost step near 4 KB that is already passed; rerun `bench_shop.py`.
- **A refreshed session cookie on a cacheable page.** `session` cannot call `no_store` (no `res`). Pages that read the session should be behind middleware that the README tells to call `web::no_store(res)`; `require_login` does it.
- **Logins block a worker** for a fraction of a second. Rate limits soften it; a dedicated hashing thread is a later option.
- **Stateless sessions:** a stolen cookie works until `exp` or a version bump. `HttpOnly`, `SameSite=Lax` and `__Host-` under HTTPS limit theft; the idle window limits the rest.
- **Rate table eviction** under many source addresses.
- **Default headers change every response's bytes** (headers only, not bodies; `/products/42` body stays identical).
- **The `.gooseweb.dev/secret` file** is readable by other local users; it is for development only, and production refuses to start without `WEB_SECRET`.
- **Linux:** `getentropy` needs glibc 2.25+ and `<sys/random.h>` there; the platform architect owns Linux builds.

## Build log

Branch `arch/auth-security`, cut from main, rebased onto v0.2.1. No Goose compiler on this machine (`$GOOSE` unset, none on PATH): **no Goose file in this work was compiled or run.** The C parts were compiled and tested with `cc`.

| Step | Commit | Tested |
|---|---|---|
| 1. Crypto core | 4bec8b4 | C: `test/crypto_test.c` 59 of 59 (NIST, RFC 4231, PBKDF2 and RFC 7914 vectors, padding edges), also under ASan/UBSan. PBKDF2 at 600,000: about 420 ms here. Goose wrappers and `crypto_test.goose` untested. |
| 2. Env, secrets, config | 89bd41b, 854a067 | C: `test/env_test.c` 12 of 12 (`gweb_setenv`). Goose `.env` loader, `WEB_SECRET` parsing, dev secret, gweb scans and `env_test.goose` untested. |
| 3. Signed cookies, sessions, passwords | 9d3ace8, 4ef0ff2 | Untested (Goose only). |
| 4. Rate limits | c5eeed0 | C: `test/rate_test.c` 18 checks, also under TSan (8 threads, exactly the limit allowed). `rate.goose` and its test untested. |
| 5. Headers, CSP, CORS | dcf5da2 | Untested (Goose only). |
| 6. Fixture, `auth.sh`, docs | 8c9b503 | `sh -n` on `auth.sh` and `release_check.sh`. The fixture's password hash checked against Python's `hashlib`. The suite itself untested. |

Review notes and fixes:
- Step 2: `env_required` printed to stdout; changed to stderr (854a067). `Keys`, `AuthConfig` and `Session` sit before `Ctx` in `web.goose`, not in the secrets section, in case Goose needs declaration before use. A blank `WEB_SECRET=` counts as unset; a bad `WEB_SESSION_IDLE` or `WEB_SESSION_MAX` exits 2.
- Step 3: `login` now refuses a negative `uid` or `ver`, which the digits-only parser would never load (4ef0ff2). MACs are compared as base64url text against a fresh encoding, so a non-canonical encoding never verifies. A refreshed `remember` cookie keeps `Max-Age = iat + max - now`. A session refresh followed by `login` or `logout` in the same request sends two lines; the last wins.
- Step 4: `gweb_now_ms` uses `CLOCK_MONOTONIC`. Clients with an unknown address (only in tests) share one bucket.
- Step 5: HSTS is sent whenever `WEB_HSTS > 0`, independent of `WEB_SECURITY_HEADERS` and `ctx.default_headers`. `csp_begin` with `WEB_CSP` off enforces. `gen_main` was missing `import web.rate;`; added.
- Step 6: login posts to `app/login/submit/route.goose` (open question 6).

First things to fix when a compiler is available, by the builders' notes: passing `u8[..N]&` to extern `u8[:]` parameters, `split_once` with three results, `time() as i64`, the `$` in a string literal, reassigning a `const u8[:]` local, NUL bytes in literals, and an unreachable `return` after `exit(2)`. Then run, in order: the five Goose tests, `test/auth.sh`, `test/release_check.sh`, and `bench_shop.py` for the `Ctx` growth and the default headers.
