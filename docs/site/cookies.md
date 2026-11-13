# Cookies

Read cookies from `req`. Set them through `ctx`. Setting works in a route, a
page loader and middleware.

```goose
let theme = gweb::cookie_or(req, "theme", "light");
let n, ok = gweb::cookie_int(req, "visits");
var v: u8[>..] = [];
let has = gweb::cookie(req, "name", v);          // percent-decoded

gweb::set_cookie(ctx, "seen", "1");
gweb::set_cookie(ctx, "theme", "dark",
    gweb::CookieOptions { max_age: 31536000, http_only: false, .. });
gweb::clear_cookie(ctx, "theme");
```

A layout can read one without a loader:

```html
<body class="{gweb::cookie_or(req, "theme", "light")}">
```

## Rules

- Defaults: path `/`, until the browser closes, `HttpOnly`, `SameSite=Lax`,
  not `Secure`. Set `secure` when the site is behind TLS.
- `CookieOptions` has `path`, `domain`, `max_age`, `secure`, `http_only` and
  `same_site`.
- `set_cookie` returns `false` and sets nothing for a bad name, path or
  domain, a broken `__Secure-` or `__Host-` rule, or a value over 1024
  encoded bytes. Check it for values from users.
- Value bytes outside `A-Z a-z 0-9 - . _ ~` are written as `%XX`. Use
  `gweb::cookie` to read them back decoded.
- All `Set-Cookie` lines of one response share 2048 bytes. If they do not
  fit, the reply is a 500.
- Clear a cookie with the same path and domain it was set with.
- There are no signed sessions in v1.

Full reference: [README](../../README.md#cookies).
