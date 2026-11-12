<!-- Produced by goose-architect on claude-fable-5-2 -->
# DESIGN-ADDENDUM-6: template syntax with one brace and `@` calls

This replaces the template syntax of DESIGN.md section 7 and of DESIGN-ADDENDUM-3 (E1, E2 markup). It applies the same way to `page.html`, `layout.html`, `not-found.html` and to the markup of `components/*.gshtml`. It changes the spelling of tags only: the generated Goose and JavaScript are the same as before.

## 1. Decisions on the user's proposal

| Proposed | Decision | Reason |
|---|---|---|
| `{expr}` escaped | **Accepted** | One brace pair per value. Inner spaces are optional: `{p.id}` and `{ p.id }` are the same. |
| `{{expr}}` raw | **Rejected; raw is `{#raw expr}`** | `{{ x }}` was the escaped form until today, and it is the escaped form in Mustache, Handlebars, Vue and Jinja. Flipping it to raw turns every unmigrated or pasted `{{ user_text }}` into an HTML injection with no error. Raw output appears once in the whole repo (a test), so the longer spelling costs nothing. |
| `@Name(expr)` or `$Name(expr)` | **Accepted as `@Name(expr)`** | `$` is already page text in the shop (`$38.61`, and `${dollars(s)}` in Qty). `@` is what Razor and Blade use for the same job. The internal name (island, component) no longer shows in templates. |

Two things I added, both from the "points to decide":

- **Partials and slot take the `@` form too:** `@shop::price(p.cents)` and `@slot()`. The rule becomes: `{ }` inserts a value, `@name( )` calls something that writes markup.
- **`{{` is a permanent build error** that names the replacement. Old syntax is removed, not deprecated.

Measured on the shop (12 templates and 3 components): 320 brace characters before, 138 after.

## 2. Grammar

A template is read one line at a time. A tag or call may not span lines (unchanged), so each HTML line is still exactly one Goose line.

```
tag      = "{" inner "}"                 the "}" is the one that matches the "{"
call     = "@" path "(" args ")"         the ")" is the one that matches the "("
path     = ident { "::" ident }          ident = [A-Za-z_][A-Za-z0-9_]*
comment  = "{--" any text "--}"          ends at the first "--}"
```

**Matching.** From the opening `{` (or `(`), nested pairs are counted and Goose literals are skipped: `"..."` with backslash escapes, `"""..."""`, and character literals such as `'}'` or `'\n'`. So `{if s.flag { "yes" } else { "}" }}` is one tag.

**Tags** (`inner` is trimmed):

| New | Old | Compiles to |
|---|---|---|
| `{expr}` | `{{ expr }}` | `web::put(out, expr);` (escaped) |
| `{#raw expr}` | `{{{ expr }}}` | `web::raw(out, expr);` |
| `{#if e}` `{#else if e}` `{#else}` `{/if}` | `{{#if e}}` … | unchanged |
| `{#for x in e}` `{#for x, i in e}` `{/for}` | `{{#for …}}` … | unchanged |
| `{#let n = e}` | `{{#let n = e}}` | unchanged |
| `{-- note --}` | `{{-- note --}}` | nothing |
| `@Name(expr)` | `{{component Name(expr)}}` | `Name::component(out, expr);` |
| `@f(a, b)`, `@ns::f(a, b)`, `@f()` | `{{> f(a, b)}}` | `f(out, a, b);` |
| `@slot()` | `{{slot}}` | `F();` (layouts only) |

**The `@` trigger rule, exactly.** `@` starts a call only when it is followed immediately by a path and then immediately by `(`. Anything else is plain text. What comes before the `@` does not matter.

| Text | Result |
|---|---|
| `@user`, `@Joe`, `joe@Example.com`, `@ (x)`, `@media (…)` | text (no `(` right after the path) |
| `$38.61`, `${s.n}` | `$` is never special; `{s.n}` is a tag |
| `@Counter(props.c)` | component (path is one identifier starting with `A`–`Z`) |
| `@shop::price(p.cents)`, `@hr()` | function call (any other path) |
| `@slot()` | the page, in a layout |
| `@Nope(1)` | error: no component named Nope |
| `@home(1)` in prose | Goose error "unknown function: home" at that line; write `&#64;home(1)` |

A capitalized path with no `::` is always a component, so a typo is a gweb error and never prints as text.

**Where braces are not tags.**

- **Inside `<script>` and `<style>` elements nothing is a tag or a call.** The text passes through unchanged, across lines, up to `</script` or `</style` (any letter case). This covers inline CSS, inline JS, JSON and JSON-LD.
- The element's own opening tag is still markup, so `<script src="{props.url}">` works, also when the opening tag spans lines.
- This is correct, not only convenient: `{expr}` escapes for HTML, which is the wrong escaping inside a script or style. To put server data in a script, write the whole element from a function: `@shop::boot_json(props)`.
- **Everywhere else every `{` opens a tag and a `}` without a `{` is an error.** A literal brace is `&#123;` or `&#125;`; a literal `@` before `name(` is `&#64;`. Entities work in text and in attribute values. `{"{"}` also works in page templates.
- There is no backslash escape and no exemption for HTML comments, `<pre>`, `<code>`, inline `onclick="…"` or `data-x='{"a":1}'`. Those last two need entities.

**`{{` is always an error**, with the replacement in the message (section 7). No valid new tag starts with `{{`.

**`{--x}`** is read as a comment start. Write `{ --x }` or `{-(-x)}` if that expression is ever needed.

## 3. Components (`cli/component.goose`)

- Markup uses the same scanner and the same tags. `@…(` in a `.gshtml` is an error, as `{{component}}`, `{{slot}}` and `{{> f()}}` were: `'@Counter()' is not available in client code (components v1)`.
- **`on:` and `bind:` values are unchanged** (`on:click="toggle(t.id)"`, `bind:value="draft"`). They hold Goose calls, not tags. The scanner passes over a whole `on:NAME="…"` or `bind:NAME='…'` value, so braces and `@` inside it are never tags: `on:click='say("{ @Foo(1) }")'` and `on:click="pick(if s.n > 1 { 1 } else { 2 })"` both work.
- **JS backend:** nothing changes behind the scanner. `m_expr`, `m_if`, `m_for`, `m_let`, `m_on`, `m_bind` receive the same offsets as before; `{#raw e}` calls `m_expr(…, raw = true)`. `<script>` and `<style>` text inside markup goes to both outputs as plain text and is not searched for `on:` or `bind:`.
- Line 1 `<script goose>` … `</script>` is handled before markup, as now.

## 4. Before and after

`examples/shop/app/page.html`, before:

```html
<p>{{ props.count }} products in the catalog. <a href="/products">See them all</a>.</p>
<ul class="grid">
{{#for p in catalog::ITEMS}}{{#if p.featured}}
<li class="card"><div class="cat">{{ p.category }}</div><a href="/products/{{ p.id }}">{{ p.name }}</a> <span class="price">{{> shop::price(p.cents)}}</span></li>
{{/if}}{{/for}}
</ul>
```

After:

```html
<p>{props.count} products in the catalog. <a href="/products">See them all</a>.</p>
<ul class="grid">
{#for p in catalog::ITEMS}{#if p.featured}
<li class="card"><div class="cat">{p.category}</div><a href="/products/{p.id}">{p.name}</a> <span class="price">@shop::price(p.cents)</span></li>
{/if}{/for}
</ul>
```

`app/components/page.html`: `{{component Counter(props.counter)}}` becomes `@Counter(props.counter)`. `app/layout.html`: `{{slot}}` becomes `@slot()`, `<title>{{ ctx.title }} | Goose Shop</title>` becomes `<title>{ctx.title} | Goose Shop</title>`.

`components/TodoBox.gshtml` markup, before:

```html
{{#for t in s.items}}
<li class="{{#if t.done}}done{{/if}}"><input type="checkbox" {{#if t.done}}checked{{/if}} on:change="toggle(t.id)"> {{ t.title }} <button on:click="remove(t.id)">x</button></li>
{{/for}}
</ul>
<p>{{ left(s) }} of {{ s.items.len }} left</p>
```

After:

```html
{#for t in s.items}
<li class="{#if t.done}done{/if}"><input type="checkbox" {#if t.done}checked{/if} on:change="toggle(t.id)"> {t.title} <button on:click="remove(t.id)">x</button></li>
{/for}
</ul>
<p>{left(s)} of {s.items.len} left</p>
```

`components/Qty.gshtml`: `Total: ${{ dollars(s) }}.{{#if rest(s) < 10}}0{{/if}}{{ rest(s) }}` becomes `Total: ${dollars(s)}.{#if rest(s) < 10}0{/if}{rest(s)}`.

## 5. Implementation

A working prototype of everything in this section is in the scratchpad (section 10). The builder can apply `proto-cli.patch` and review it, or re-type it.

### New file `goose-web/cli/tscan.goose` (`namespace tscan;`)

Imported by `gweb.goose` and `component.goose`. Pure functions over one line; no globals.

```goose
let MARKUP = 0;  let SCRIPT_TAG = 1;  let SCRIPT = 2;  let STYLE_TAG = 3;  let STYLE = 4;
fn is_raw(st: i64) -> bool                                   // SCRIPT or STYLE
fn brace_end(line: const u8[:], at: i64) -> i64              // matching '}' of line[at] == '{', or -1
fn paren_end(line: const u8[:], at: i64) -> i64              // matching ')' of line[at] == '(', or -1
fn call_open(line: const u8[:], at: i64) -> i64              // line[at] == '@': index of its '(', or -1
fn raw_end(line: const u8[:], from: i64, st: i64&) -> i64    // st raw: the '<' of </script or </style (st = MARKUP), or line.len
fn next(line: const u8[:], from: i64, st: i64&, attrs: bool) -> i64
fn old_syntax(rest: const u8[:]) -> const u8[:]              // the message for a "{{..." at rest
```

`next` returns the index of the next `{`, `}` or `@` call, or `line.len`. When a `<script …>` or `<style …>` opening tag closes first, it sets `st` raw and returns the index after that `>`. `attrs = true` makes it pass over `on:`/`bind:` attribute values (components). The state `st` lives across the lines of one file.

The caller's loop, the same in both compilers:

```
while pos < line.len {
    if tscan::is_raw(st) { e = raw_end(line, pos, st); literal(line[pos..e]); pos = e; continue; }
    at = tscan::next(line, pos, st, attrs); text(line[pos..at]); pos = at;
    if at == line.len || tscan::is_raw(st) { continue; }
    '}'   -> error
    '@'   -> open = call_open, close = paren_end(open); name = line[at+1..open]; args = trim(line[open+1..close])
    "{{"  -> error old_syntax
    "{--" -> skip to "--}"
    '{'   -> e = brace_end; inner = trim(line[at+1..e]); dispatch on inner
}
```

### `goose-web/cli/gweb.goose`

- `import tscan;`
- `compile_template` (same signature) is rewritten around the loop above. Its tag dispatch moves into two new functions:

```goose
fn template_tag(path: const u8[:], ln: i64, inner: const u8[:], stack: u8[>..]&, stack_lines: i64[>..]&, out: u8[>..]&)
fn template_call(path: const u8[:], ln: i64, name: const u8[:], args: const u8[:], layout: bool, out: u8[>..]&)
```

- The "layout needs a slot" check counts `@slot()` calls during the compile instead of searching the source text.
- `scaffold()`: the five template strings in the new syntax.
- Header comments.
- Not touched: `gen_template`, `gen_components`, `add_default_imports`, `rewrite_errors`, `component_lines_back`, `test_cmd`, `dev`, everything about routes and statics.

### `goose-web/cli/component.goose`

- `import tscan;` and a new global `var raw_st = 0;`, reset in `compile_markup`.
- `markup_line` is rewritten around the loop above (it copies the line into a local buffer and passes absolute offsets to `m_text`, `m_if` and the others, as before).
- Six error strings in `m_if`, `m_else`, `m_close`, `compile_markup` lose their double braces.
- Comments that show tags.
- Not touched: the script parser, type checker, JS emitter, `m_expr`, `m_for`, `m_let`, `m_on`, `m_bind`, `m_text`, `next_attr`, `compile`.

### Not in the prototype; the builder adds

- `{#raw}` and `{#if}` with nothing after the word: report `{#raw e} needs an expression` (today they fall to `unknown tag {#raw}`).
- At the end of a file with `st != MARKUP`: `<script> is never closed with </script>` (or `<style>`), at the line of the opening tag. Without it an unclosed element silently makes the rest of the file literal.

## 6. Every file changed

**Code**
- `goose-web/cli/tscan.goose` (new)
- `goose-web/cli/gweb.goose`
- `goose-web/cli/component.goose`
- `goose-web/template.goose` (two comments: `{expr}`, `{#raw expr}`)
- `goose-web/gweb` (the binary, rebuilt: `goose build -o gweb cli/gweb.goose`)

**Shop** (`goose-web/examples/shop/`)
- `app/layout.html`, `app/not-found.html`, `app/page.html`
- `app/products/page.html`, `app/products/[id]/page.html`
- `app/components/page.html`, `app/components/products/[id]/page.html`
- `app/db/page.html`, `app/db/products/page.html`, `app/db/products/[id]/page.html`
- `app/todos/page.html`
- `components/Counter.gshtml`, `components/Qty.gshtml`, `components/TodoBox.gshtml`
- `lib/shop.goose` (one comment)
- `app/about/page.html` has no tags and does not change.

**Tests**
- `goose-web/test/components/*.gshtml`: all 38 files (markup lines; one comment in `Nested.gshtml`), plus the new files in section 8
- `goose-web/test/templates.sh` and `goose-web/test/templates/` (new, section 8)
- `goose-web/test/components.sh`: no change needed

**Docs**
- `goose-web/README.md`: the file table (line 24), the syntax table (lines 53–60), the component section (lines 131, 141–149), plus a short "literal braces and @" paragraph with the three entities and the `<script>`/`<style>` rule
- `goose-web/DESIGN.md` section 7 and `goose-web/DESIGN-ADDENDUM-3.md`: one banner line each pointing here (as the rename banner does); the text stays as history
- `goose-web/DESIGN-ADDENDUM-6-SYNTAX.md` (this file)

**Not changed**
- `goose-web/web.goose`, `static.goose`, `owner.goose`, `client/gwi.js`, `client/gwi.min.js`, `goose-net`, `goose-sqlite`
- `goose-bench/shop/check_site.py` and `baseline/products_42.html`: the output is the same, so the baseline stays and is the proof
- The Next twins. The `{{` in `goose-bench/shop/gen_data.py` are Python f-strings.

**Migration tool.** `migrate.py` in the scratchpad rewrites `.html` templates and `.gshtml` markup in place. I used it on all of the files above. It is a one-off; do not ship a `gweb migrate` command. Old syntax is removed outright, and the `{{` errors tell anyone else what to write.

## 7. Error messages

All are `path:line: error: MESSAGE` as today (`components/Name.gshtml:LINE` for components). Line mapping is unchanged: one HTML line is one Goose line, so a Goose error inside `{expr}` still reports the template's own line.

| Input | Message |
|---|---|
| `{{ x }}` | `'{{ e }}' is the old syntax: write {e} (escaped) or {#raw e} (not escaped)` |
| `{{{ x }}}` | `'{{{ e }}}' is the old syntax: write {#raw e}` |
| `{{> f(1)}}` | `'{{> f(a)}}' is the old syntax: write @f(a)` |
| `{{component N(e)}}` | `'{{component Name(e)}}' is the old syntax: write @Name(e)` |
| `{{slot}}` | `'{{slot}}' is the old syntax: write @slot()` |
| `{{#if e}}`, `{{/if}}` | `'{{#tag}}' is the old syntax: write it with one brace, as in {#if e} and {/if}` |
| `{{-- x --}}` | `'{{-- --}}' is the old syntax: write {-- note --}` |
| `a } b` | `'}' without '{'; for a literal brace write &#125;` |
| `{ctx.worker` | `{ needs } on the same line; for a literal brace write &#123;` |
| `{}` | `empty { }` |
| `{#when x}` | `unknown tag {#when x}` |
| `{-- x` | `{-- needs --} on the same line` |
| `{#if e}` unclosed | `{#if} is never closed with {/if}` (same for `{#for}`) |
| `{/for}` alone | `{/for} does not close an open {#for}` (same for `{/if}`) |
| `{#else}` alone | `{#else} outside {#if}` (same for `{#else if}`) |
| `@Nope(1)` | `no component named Nope (there is no components/Nope.gshtml); for a literal @ write &#64;` |
| `@f(1` | `@name( needs its ) on the same line; for a literal @ write &#64;` |
| `@slot()` in a page | `@slot() is for layout.html only` |
| `@slot(1)` | `@slot() takes no arguments` |
| layout without it | `a layout needs @slot() where the page goes` |
| `@C(s)` in a `.gshtml` | `'@C()' is not available in client code (components v1)` |

A build stops at the first scanner error on a line in a page template (as today); components report and continue (as today).

## 8. Tests to add

**Component suite (`test/components/`)**
- `Syntax.gshtml` (parity, Goose against JS, pretty and compact) with one `test_*` function and this markup:
  - `{if s.n > 2 { "}" } else { "{" }}` (nested braces and braces in strings)
  - `${s.n}`, `$38.61`, `@user`, `a@b.co` as text
  - `&#123;literal&#125;`
  - a `<style>` block with `{ }` and `@media(min-width: 10px)`, and an inline `<script>` with an object literal
  - `on:click='say("{ @Foo(1) }")'` and `on:click="pick(if s.n > 1 { 1 } else { 2 })"`
  - `{#raw s.n}` and `{-- a note with { } and @x() --}`
- Expected failures, each with its `// expect:` line: `FailOldSyntax` (`{{ s.n }}`), `FailStrayBrace` (`{s.n}}`), `FailOpenBrace` (`{s.n`), `FailCall` (`@Other(s)`), `FailRawEmpty` (`{#raw }`).
- The parity count rises from 36 by two cases per mode (the new file's `zero` and its test).

**Page templates: new `test/templates.sh`** (there is no page-template suite today)
- One project whose `page.html` holds the cases below; build it, start it, and compare `GET /` with a committed `expect.html`:
  - text `@user joe@Example.com $38.61 ${props.n} @ (x)`
  - `@util::stars(props.n)` and `@util::hr()` (calls with and without arguments)
  - `{if props.n > 2 { "}}" } else { "{" }}` and `{'}' as i64}`
  - `&#123;x&#125;` and `{#raw props.url}`
  - a `<style>` block containing `{props.url}` and `@media(max-width: 5px)`: must come out unchanged
  - a `<script` opening tag over two lines with `src="{props.url}"`, a body containing `{"b": "{{ not a tag }}"}` and `@decorator(j)`, then `</script><b>{props.n + 1}</b>` on the closing line
  - `<script type="application/ld+json">{"@context": "https://schema.org"}</script>`
  - a component call `@Name(props.state)`
- Each row of the section 7 table as an expected failure with its line number.
- A wrong field (`{ctx.nope}` on line 2) must report `app/page.html:2`.

**Acceptance for the migration (run once by the builder)**
1. Before touching anything: `gweb gen` in the shop, keep a copy of `.gooseweb/`.
2. After the change and the migration: `gweb gen` again; every file must be byte-identical to the copy.
3. `test/components.sh` passes; `gweb test` passes in the shop.
4. `check_site.py --components` passes, including the byte-identical `/products/42`.
5. `gweb new x && cd x && gweb build` succeeds.

## 9. For the two parallel builders

My change touches: `cli/tscan.goose` (new), `cli/gweb.goose` (`compile_template`, new `template_tag` and `template_call`, `scaffold`, one `import`), `cli/component.goose` (`markup_line`, `compile_markup`, four message strings, one global), comments in `template.goose`. It does not touch `web.goose`, `client/gwi.js` or `goose-net`.

**Server fragments (addendum 4)**
- The tags are `{#fragment NAME}` and `{/fragment}`. Add them as two more branches in `template_tag`; they need no scanner change (`todo-list` is taken as text, not parsed).
- Addendum 4 changes `layout: bool` to a kind and returns fragment names: apply that to `compile_template` and to `template_call` (which takes `layout`).
- "No component inside a fragment" is checked in `template_call`; the message becomes `@Name() cannot be inside {#fragment} (fragments v1)`.
- `scan_targets`: where it says "skipping `{{…}}` spans", use `tscan::brace_end`; a URL segment containing `{` is the wildcard.
- The `gen_template` pre-scan looks for `{#fragment `.
- In a `.gshtml` the tag fails with `unknown tag {#fragment …}` with no change.
- Every message in addendum 4 loses its double braces.

**Cookies (addendum 5)**
- No code overlap. Its demo template and README lines use `{expr}`, `{#if e}`, `{#else}`, `{/if}`.

## 10. What I verified, and what I did not

Scratchpad: `/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-syntax/`

- `gw-old/` is an untouched copy of goose-web; `gw-new/` has the change and the migrated files.
- `proto-cli.patch` (415 lines), `proto-examples.patch`, `proto-test.patch`: the diffs between them.
- `migrate.py`: the migration script. `edge2/` and `errp/`: the edge-case and error projects.

**Verified by running the prototype**
- `goose check` and `goose build` accept `tscan.goose`, `gweb.goose` and `component.goose`.
- The shop's generated output is byte-identical: all 39 files in `.gooseweb/` (page templates, the three components' Goose, the compact JS) match the old gweb on the old syntax.
- `test/components.sh` on the migrated suite: 33 passed, 0 failed; 36 parity cases pass, pretty and compact.
- The shop built with the prototype passes `check_site.py --components`, and `/products/42` matches `baseline/products_42.html` byte for byte.
- `gweb new` then `gweb build` works with the new scaffold, and the page renders.
- The edge page and edge component in section 8 render as described; `gweb test` passes on the edge component.
- Every message in section 7 was produced by the prototype, with the right `path:line`.

**Not verified**
- Nothing in a browser: the morph over a component that contains `<style>` or `<script>` is existing behaviour I did not exercise.
- `gweb dev` (pretty JS output) was covered only through the parity suite, not by a file diff.
- `goose-bench` benchmark runs.
- The two additions listed at the end of section 5 are not in the prototype.
- No doc file was edited.

I changed nothing outside the scratchpad and committed nothing. A dev server was already running on port 3980; I left it alone.

## 11. Rejected alternatives

- **`{{expr}}` as raw:** silent injection for any unmigrated or pasted `{{ }}`, and the opposite of every other template language.
- **Accept old syntax with a deprecation warning:** `{{ x }}` cannot be both old-escaped and anything else; two grammars in two compilers for a codebase that migrates in one script.
- **`$Name(expr)`:** `$` is already price text in the shop and sits directly before a tag in Qty.
- **`{Name(expr)}` for components:** indistinguishable from an escaped call to a function.
- **`@Name(...)` only when `Name` is a known component, else text:** a typo would print the call on the page.
- **`@` must not follow a letter or digit (email guard):** `x@f(1)` would silently be text; emails have no `(` after the name anyway.
- **`{slot}` and `{> f()}` kept in braces:** two more special words inside `{ }`, and `slot` could no longer be a variable name.
- **A backslash escape (`\{`):** entities already work in text and attributes, and need no code.
- **`{` followed by a space is literal:** `{ p.id }` is how every existing tag is written.
- **Exempt `onclick="…"`, `data-*` JSON or HTML comments:** each needs an attribute parser in page templates; entities cover the rare case.
- **Interpolation inside `<script>`/`<style>`:** collides with CSS and JS braces, and HTML escaping is wrong there.
- **A shipped `gweb migrate` command:** one-off work for about 55 files.
- **Scanner code duplicated in both compilers:** the two would drift; `tscan.goose` keeps one copy.

## 12. Risks

- **Literal braces outside `<script>`/`<style>` now need entities.** Inline `onclick="if (x) { … }"` and `data-x='{"a":1}'` fail to build until rewritten. The failure is a Goose error on the right line, not a wrong page, but the message is the compiler's (`expected ')' in call arguments`), not a hint about braces.
- **Prose containing `@word(`** becomes a call. It fails the build (unknown function or component); it never renders wrongly.
- **Raw-text detection is textual.** A `>` inside a quoted attribute of a `<script …>` opening tag ends the tag early; `</script` inside a JS string ends the raw text (browsers do the same); `<script` inside an HTML comment or attribute value starts raw text. The unclosed-element error in section 5 limits the damage.
- **No server values inside inline scripts or styles any more.** `<style>h1 { color: {x}; }</style>` now prints `{x}` literally and silently. Old templates that did this do not exist in the repo, but it is a behaviour change to document in the README.
- **A function partial with a capitalized, un-namespaced name** (`@Price(x)`) is taken as a component and rejected. Use a lower-case name or `ns::`.
- **Three designs touch `compile_template`.** This one must merge first; the fragments builder rebases onto `template_tag`/`template_call` as section 9 describes.
- **Character-literal skipping is heuristic** (`'x'`, `'\n'`, `'\x41'`). An apostrophe elsewhere in an expression is treated as an ordinary character, which is right for Goose as specified, but a new literal form in a later Goose version would need a scanner update.

## Follow-up 1

Both stay as built; nothing needs appending as a follow-up unless you want the record below.

1. **Bare `{#if}`:** keep `{#if e} needs an expression`. It matches the `{#raw e}` wording. If a bare `{#else if}` or `{#let}` currently falls through to `unknown tag`, give them the same form (`{#else if e} needs an expression`, `{#let n = e} needs a name and a value`); a bare `{#for}` is already covered by the existing `{#for x in e} or {#for x, i in e}` message.

2. **Layout without `@slot()`:** keep the line-less form, `app/layout.html: error: a layout needs @slot() where the page goes`. The slot is missing from the whole file, so no single line is correct, and line 0 is how the old `{{slot}}` check reported it too. Section 7's statement that every message is `path:line` is too broad for this one row; the `test/templates.sh` expectation stands.

I did not implement or edit anything.
