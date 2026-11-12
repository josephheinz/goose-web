# Fragments

A link or form marked `gw-target="NAME"` fetches its normal URL. The server
answers with only the `{#fragment NAME}` region of that page. The browser
swaps it into the element with `id="NAME"`. Without JavaScript the link or
form does a normal navigation.

```html
<ul id="todo-list">{#fragment todo-list}
{#for t in props.todos}<li gw-key="{t.id}">{t.title}</li>{/for}
{/fragment}</ul>
<form method="post" action="/todos" gw-target="todo-list">
  @web::csrf_field(ctx)
  <input name="title"> <button>Add</button>
</form>
<a href="?cat=home" gw-target="results">home</a>
```

The page's `page.goose` handles the post:

```goose
fn POST(req: const http::Request&, ctx: web::Ctx&) -> Props {
    ...
}
```

## Rules

- A fragment is a region of a `page.html`. Not a layout, not a component.
- It goes right after the opening tag that has `id="NAME"`, on the same
  line. `{/fragment}` goes right before that element's closing tag.
- A page has at most 8 fragments. None inside `{#if}`, `{#for}` or another
  fragment, and no `@Component()` inside.
- `gw-target` goes on `<a href>` or `<form>`. `gweb` checks at build time that
  the URL reaches a page with that fragment, and that `method="post"` has
  `fn POST(` in that page.
- The request carries `GW-Fragment: NAME`. The reply echoes it. An unknown
  name gives the whole page.
- Give `gw-key` to every item of a list that can be reordered or lose an
  item other than the last.
- `fn POST(req, ctx) -> Props` runs in place of `load` for a POST. It needs
  `load`. A POST must carry the CSRF token.
- `import web.form;` gives `web::form(req, "name", out)` and
  `web::form_int(req, "id")`.
- Not supported: file uploads, append or prepend swaps, a target inside a
  component.

Full reference: [README](../../README.md#fragments).
