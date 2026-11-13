# Routing

A folder under `app/` is a URL segment. What is inside says what answers.

| File | Meaning |
|---|---|
| `page.html` | a page |
| `page.goose` | `Props`, `fn load`, optional `fn POST` for that page |
| `route.goose` | an API endpoint: `fn GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS` |
| `layout.html` | wraps every page at or below its folder |
| `middleware.goose` | `fn before` and/or `fn after` for the subtree |
| `app/not-found.html` | the 404 page |

```
app/layout.html            wraps everything
app/page.html              /
app/blog/[id]/page.html    /blog/7
app/api/time/route.goose   /api/time
```

A route answers with plain handlers:

```goose
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    gweb::json(res, http::Status.Ok);
    res.body.append("{}");
}
```

A page loads its data, then the template shows it:

```goose
struct Props { name: const u8[:] }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    ctx.title.append("Hello");
    return Props { name: gweb::param(ctx, "name") };
}
```

## Rules

- `[id]` is a dynamic segment. `gweb::param(ctx, "id")` reads it.
  `gweb::param_int` reads an integer.
- `[...slug]` matches one or more trailing segments, `[[...slug]]` zero or
  more. `gweb::param` returns the raw tail.
- A literal folder beats `[id]`, which beats a catch-all.
- `public/` files are tried first for GET and HEAD.
- Folders starting with `_` are ignored.
- App files get their namespace from `gweb`. Do not write one.
- `before` returns `false` to stop the request. `res` is then the answer.
- Set `ctx.title` in `load`. The layout reads it.
- `gweb::not_found(ctx)` gives the 404 page. `gweb::redirect(ctx, "/to", 302)`
  redirects.
- A `[id]` value is not checked. Never join it to a file path as it is.

Full reference: [README](../../README.md#project-layout),
[signatures](../../README.md#signatures),
[catch-all routes](../../README.md#catch-all-routes).
