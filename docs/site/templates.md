# Templates

`page.html` and `layout.html` are templates. Tags are Goose expressions.
The compiler type-checks them, so a wrong field name is a build error.

```html
<h1>{props.title}</h1>
{#if props.items.len == 0}
<p>Nothing here.</p>
{#else}
<ul>
{#for item, i in props.items}
  <li>{i + 1}. {item.name} @price(item.cents)</li>
{/for}
</ul>
{/if}
```

| Syntax | Does |
|---|---|
| `{expr}` | writes the value, HTML-escaped |
| `{#raw expr}` | writes it raw |
| `{#if e}` `{#else if e}` `{#else}` `{/if}` | conditions |
| `{#for x in e}`, `{#for x, i in e}`, `{/for}` | loops |
| `{#let n = e}` | a local |
| `@f(a)`, `@ns::f(a)` | calls `f(out, a)` |
| `@Name(expr)` | a component |
| `@slot()` | the page, in a layout |
| `{-- note --}` | a comment |

## Rules

- In scope: `req`, `ctx`, `props` (when `load` exists), and what `page.goose`
  imports.
- A tag stays on one line. Each HTML line compiles to one Goose line, so
  compiler errors point at your HTML line.
- A literal brace is `&#123;` or `&#125;`. A literal `@` before `name(` is
  `&#64;`.
- Inside `<script>` and `<style>` nothing is a tag. The text passes
  through.
- Use `{#raw}` only for text you trust.

Full reference: [README](../../README.md#templates).
