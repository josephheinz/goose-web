# Forms and CSRF

Every page `fn POST` and every `route.goose` with `POST`, `PUT`, `PATCH` or
`DELETE` checks a CSRF token. A request without it gets 403.

```html
<form method="post" action="/notes">
  @gweb::csrf_field(ctx)
  <input name="text">
  <button>Add</button>
</form>
```

```goose
var text: u8[>..] = [];
gweb::form(req, "text", text);        // import gweb.forms.form;
```

A script sends the token in a header instead:

```html
<meta name="csrf-token" content="{gweb::csrf_token(ctx)}">
```

It sends that value as `X-CSRF-Token`.

## Rules

- The token is a cookie, `gw_csrf`, with the same value in a hidden `_csrf`
  field. `_csrf` is a reserved field name.
- `gweb` starts the token for a page whose `page.html`, `page.goose` or
  layout mentions `gweb::csrf_`. A field written in a `lib/` partial is not
  seen. Call `gweb::csrf_begin(req, ctx, res)` from `before` middleware then.
- A form with `gw-target` sends its hidden field with the fragment POST.
- A bad token gets 403. A request with `Sec-Fetch-Site` other than
  `same-origin` or `none` gets 403 too.
- A route opts out with `const CSRF = false;` on a line of its own. Use it
  for APIs called by clients that are not browsers, and for webhooks. Such a
  route must not trust cookies. Pages cannot opt out.
- Behind a proxy that sends `X-Forwarded-Proto: https` the cookie is
  `__Host-gw_csrf` with `Secure`.

Full reference: [README](../../README.md#csrf).
