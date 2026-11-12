# Components

A component is a part of a page that runs in the browser. It is written in
a subset of Goose. Its code runs on the server for the first render, and
as JavaScript in the browser.

`components/Counter.gshtml`:

```
<script goose>
struct State { count: i64 }
fn inc(s: State&) { s.count += 1; }
fn test_basic(s: State&) { inc(s); inc(s); }
</script>
<button on:click="inc">Clicked {s.count} times</button>
```

Use it in a page, with a `Counter::State` from `load`:

```html
@Counter(props.counter)
```

In `page.goose`, write `import Counter;` to use `Counter::State` in `Props`.

## Rules

- The file is `components/Name.gshtml`. `Name` is `[A-Z][A-Za-z0-9]*`.
  Line 1 is exactly `<script goose>`. A line that is exactly `</script>`
  ends the script. The markup follows and reads the state as `s`.
- The script needs `struct State`. Field types: `i64`, `bool`, `u8[..N]`,
  structs of the block, and one `Name[>..<]` as the last field.
- A handler takes `s: State&` first. Call it with `on:click`, `on:change`,
  `on:input` or `on:submit`, as `on:click="remove(t.id)"`.
- `bind:value="field"` and `bind:checked="field"` tie an input to a field of
  `State`.
- The client subset leaves out `match`, `enum`, floats, `loop`, `guard`,
  `defer`, closures, slices, `as`, bitwise operators, generics, globals and
  imports. `gweb` reports anything else as
  `components/Name.gshtml:LINE: error:`.
- `test_*` functions take only `s: State&`. `gweb test` runs them as Goose
  and as JavaScript and compares the results.
- A component cannot be inside a fragment.
- State lives in the page only. Handlers get no event data.

Full reference: [README](../../README.md#implementation-notes-components).
