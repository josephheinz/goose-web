<!-- Produced by goose-architect on claude-fable-5-2 -->
# DESIGN-ADDENDUM-4: server fragments (option B)

A link or form marked `gw-target="NAME"` fetches its normal URL, and the server answers with only the `{{#fragment NAME}}` region of that page, without the layout. The runtime morphs the reply into the element with `id="NAME"`. Everything below is decided; the builder should not need to ask.

## Rename mapping

I agree with the mapping as given, and this design uses the component names throughout.

## Template syntax note

Template examples here use the current syntax. The final spelling of `{{#fragment NAME}}` / `{{/fragment}}`, and of the expression holes the URL check treats as wildcards, follows DESIGN-ADDENDUM-6-SYNTAX.md once it lands. The fragment tag is a block tag like `{{#if}}` and takes whatever form that addendum gives block tags.

## What I verified and what I did not

Prototype in `/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-fragments/w/` (a copy of goose-web, goose-net and goose-sqlite).

**Verified by building and running:**
- **Server side:** `web.goose` with the `Ctx` field and the `run_worker` line, `form.goose` exactly as in section 3, and the generated code of section 4 (hand-edited into the shop's `.gooseweb/`) compile with `goose build` and behave as specified under curl.
  - A fragment reply has only the region, the `GW-Fragment` echo, `Cache-Control: no-store`, and no dev script under `--dev-id`.
  - An unknown fragment name gives the whole page without the echo.
  - POST, form decoding (`+`, `%XX`, UTF-8, escaping), the 403 on `Sec-Fetch-Site: cross-site`, and the 405 with `Allow: GET, HEAD, POST, OPTIONS` all work.
- **Runtime:** the code in section 6, minified with esbuild 0.28.2, is 3,133 bytes (1,676 gzipped; today's file is 2,187 and 1,244).
- **Browser (Chromium pane, minified runtime):**
  - Add, done, undo and remove update the list with no reload.
  - The input is cleared and keeps focus and its element identity.
  - A validation error shows and then clears.
  - A GET link and a GET form (query `q=a+b%26c`) both swap.
  - A 404 raises one `gw:error` and the dev overlay shows it.
  - A reply without the echo becomes a normal navigation.
  - A meta-click and a link with no target element are left to the browser.
  - The Counter component still works after the `oops`/`swap` refactor.

**Not built or run:**
- The gweb changes: the `{{#fragment}}` compile, the `gw-target` scanner and URL check, script-tag insertion, and `gweb routes`.
- The products demo pages, `test/fragments.sh`, and the `check_site.py` additions.
- A 303 from an action followed by fetch with the header kept. That is fetch-spec behaviour and I did not test it.
- Firefox and Safari.

**Found while prototyping:** if whitespace sits between the target's opening tag and the region, the DOM and the reply misalign and morph replaces every node (the focused input was replaced). Section 2's same-line rule exists to prevent that.

## 1. Model

- **Fragment:** a named region of a `page.html`. The page's own URL serves it. There are no separate fragment files or routes.
- **Request:** the normal URL plus the header `GW-Fragment: NAME`.
- **Reply:** the region's HTML only, with `GW-Fragment: NAME` echoed and `Cache-Control: no-store`. No layout, no rest of the page, no dev script.
- **Trigger:** `gw-target="NAME"` on `<a href>` (click) or `<form>` (submit). It is the only attribute.
- **Swap:** morph the children of `#NAME` to the reply. This is the only swap mode.
- **Without JavaScript:** the same link or form does a normal navigation and gets the whole page.
- **Mutations:** `page.goose` may define `fn POST`, which runs in place of `load` for POST requests.

## 2. Template syntax

```html
<ul id="todo-list">{{#fragment todo-list}}
{{#for t in props.todos}}<li>{{ t.title }}</li>{{/for}}
{{/fragment}}</ul>
```

Rules, each a gen error at the tag's line:

| Rule | Message |
|---|---|
| Only in `page.html` | `{{#fragment}} is for page.html only` |
| Name is `[A-Za-z][A-Za-z0-9_-]*`, at most 64 bytes | `a fragment name is [A-Za-z][A-Za-z0-9_-]*, at most 64 bytes` |
| Not inside `{{#if}}`, `{{#for}}` or another fragment | `{{#fragment}} cannot be inside {{#if}}, {{#for}} or another {{#fragment}}` |
| The text before the tag on its line ends with `>`, and that opening tag (back to its `<`) contains `id="NAME"` | `{{#fragment NAME}} goes right after the opening tag that has id="NAME", on the same line` |
| The text after `{{/fragment}}` starts with `</` | `{{/fragment}} goes right before the closing tag of the element` |
| Balanced | `{{#fragment}} is never closed with {{/fragment}}` and `{{/fragment}} does not close an open {{#fragment}}` |
| Unique in the page | `two fragments named NAME` |
| At most 8 per page | `a page has at most 8 fragments` |
| No component inside | `{{component}} cannot be inside {{#fragment}} (fragments v1)` |

In `components/*.gshtml` the tag already fails with `unknown tag {{#fragment …}}`; `cli/component.goose` does not change.

**A fragment sees `props`, `req` and `ctx` only.** A top-level `{{#let}}` ends at the next `{{#fragment}}` or `{{/fragment}}`, because each stretch compiles to its own block. Using such a name across the boundary is a Goose "unknown name" error at the right line.

The tags emit no bytes, so the whole page is byte-identical with or without them.

## 3. Goose API

### `page.goose`

```goose
fn load(req: const http::Request&, ctx: web::Ctx&) -> Props                 // unchanged
fn POST(req: const http::Request&, ctx: web::Ctx&) -> Props                 // new, optional
```

- `POST` handles a POST to the page's URL and returns the props to render, usually `var p = load(req, ctx); p.error = …; return p;`.
- `POST` without `load` is a gen error: `fn POST( needs fn load( beside it` (at `page.goose`).
- `web::redirect` and `web::not_found` work in `POST` as in `load`.
- A POST without the `GW-Fragment` header renders the whole page with status 200. An action that wants post-redirect-get calls `web::redirect(ctx, "/x", 303)`.
- Only POST is supported; HTML forms have no PUT or DELETE. Several intents on one page are told apart by button names: `<button name="remove" value="3">`.

### New file `goose-web/form.goose` (`import web.form;`)

This text compiled and ran in the prototype:

```goose
// Part of goose-web. Import with `import web.form;`.
namespace web;
import std;
import net from "../goose-net";
import net.http;
import web;

// A field of a form posted as application/x-www-form-urlencoded, URL-decoded
// and appended to out. False when absent.
fn form(req: const http::Request&, name: const u8[:], out: u8[>..]&) -> bool {
    each_split(req.body, '&') { pair =>
        let key, value, has = split_once(pair, '=');
        if key == name { http::url_decode(out, value); return true; }
    };
    return false;
}

// A form field as an integer.
fn form_int(req: const http::Request&, name: const u8[:]) -> i64, bool {
    var v: u8[>..] = [];
    if !form(req, name, v) { return 0, false; }
    return parse_int(trim(v));
}

// The fragment a request asks for (its GW-Fragment header); "" for a whole page.
fn fragment(req: const http::Request&) -> const u8[:] {
    let v, has = http::header(req, "gw-fragment");
    return if has { trim(v) } else { "" };
}

// Which of a page's fragments the request asks for: 1 for names[0], 2 for
// names[1]...; 0 for the whole page (no header, or a name the page lacks).
fn fragment_index(req: const http::Request&, names: const u8[:][:]) -> i64 {
    let want = fragment(req);
    if want.len == 0 { return 0; }
    for n, i in names { if n == want { return i + 1; } }
    return 0;
}

// Marks the reply as a fragment: echoes the name in GW-Fragment, forbids
// caching, and keeps gweb dev's script out of it.
fn fragment_reply(req: const http::Request&, ctx: Ctx&, res: http::Response&) {
    ctx.fragment = true;
    http::set_header(res, "GW-Fragment", fragment(req));
    http::set_header(res, "Cache-Control", "no-store");
}

// A browser says this request comes from another site (Sec-Fetch-Site:
// cross-site). Generated page code refuses such a POST.
fn cross_site(req: const http::Request&) -> bool {
    let v, has = http::header(req, "sec-fetch-site");
    return has && trim(v) == "cross-site";
}
```

Users call `web::form` and `web::form_int`. The other four functions are for generated code.

## 4. Generated code

**Pages with no fragment and no `POST` generate exactly what they do today**, so `/products/42` and the benchmark are untouched.

**Template (`pN_x_html.goose`), when the page has at least one fragment:**
- The render signature gains a last parameter `gw_part: i64`. `gen_template` pre-scans the source for `{{#fragment ` and inserts `, gw_part: i64` before the signature's final `)`.
- The header line ends with `if gw_part == 0 { `.
- The K-th `{{#fragment}}` (from 1) emits `} if gw_part == 0 || gw_part == K { `.
- `{{/fragment}}` emits `} if gw_part == 0 { `.
- The final `}` becomes `} }`.
- Line-for-line mapping is unchanged.

**`page_N` in `main.goose`,** for a page with fragments `a`, `b`, a `POST` and one layout:

```goose
fn page_17(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    match req.method {
        Get, Head, Post => {},
        Options => { web::options(res, "GET, HEAD, POST, OPTIONS"); return; },
        _ => { web::method_not_allowed(res, "GET, HEAD, POST, OPTIONS"); return; },
    }
    /* middleware before, as now */
    web::html(res, http::Status.Ok);
    let part = web::fragment_index(req, ["a", "b"]);
    if req.method == http::Method.Post {
        if web::cross_site(req) { http::text(res, http::Status.Forbidden, "cross-site POST refused\n"); return; }
        let props = p17_x::POST(req, ctx);
        if ctx.outcome == web::Outcome.Continue {
            if part > 0 { web::fragment_reply(req, ctx, res); p17_x::render(res.body, req, ctx, props, part); }
            else { l0::render(res.body, req, ctx) { p17_x::render(res.body, req, ctx, props, 0); }; }
        }
    } else {
        let props = p17_x::load(req, ctx);
        if ctx.outcome == web::Outcome.Continue { /* the same two lines */ }
    }
    /* middleware after, as now */
}
```

- Without `POST`: the method match and the single branch stay as today.
- Without fragments: no `part`, no `gw_part` argument, no `fragment_reply`.
- Without `load`: no `props`.
- The two branches are separate statements, not one `match` expression, so `load` and `POST` are not forced to return the same type by generated code.
- `gen_main` adds `import web.form;` after `import web.owner;`.
- `finish()` is unchanged. A NotFound outcome on a fragment request sends the normal 404 page with status 404, which the runtime reports and does not swap.

## 5. Attribute syntax and the build-time URL check

```html
<a href="/fragments/products/{{ p.id }}" gw-target="detail">Quick view</a>
<form method="post" action="/fragments" gw-target="todo-list"> … </form>
<a href="?cat=home" gw-target="results">home</a>
```

**Script tag.** A template that contains `gw-target="` gets `<script type="module" src="/_gw/gwi.js"></script>` added by gweb:
- `page.html` and `not-found.html`: at the start of the output, inside the `if gw_part == 0` block when there is one.
- `layout.html`: immediately before the slot.
- Duplicates are harmless, since a module runs once.
- gweb ships `/_gw/gwi.js` when the project has a component or any `gw-target`.

**Scanner.** New `scan_targets(path, src, own)` in `cli/gweb.goose`, run on the raw text of every `page.html`, `layout.html`, `not-found.html` and `components/*.gshtml`. `own` is the page's dir index, or -1. For each `gw-target="` on a line:
1. The tag runs from the last `<` before it to the next `>` after it, skipping `{{…}}` spans and quoted values. It must be on one line and be `a` or `form`.
2. `NAME` must be a literal fragment name.
3. The URL is `href` (for `a`) or `action` (for `form`, where absent means empty). The method is `method`, compared without case; absent means get.
4. Each reference is recorded as `{path, line, url, name, post, own}` in a global list, and `uses_fragments` is set.

**Check.** New `check_targets()`, called in `gen()` after the dir loop, so every page's fragments and `POST` flag are known, and before the `errors > 0` test. For each reference:
- An empty URL or one starting with `?` means the page itself. That is allowed only when `own >= 0`.
- Otherwise the URL must start with `/`. Cut it at the first `?` or `#` and split on `/`.
- A segment containing `{{` is a wildcard.
- The match is the first dir with a route or page, in the dispatcher's order (same count, `route_before`), where every segment fits:
  - a literal fits an equal literal or a `[name]`;
  - a wildcard fits only a `[name]`.

Messages, as `path:LINE: error: …`:
- `gw-target goes on <a href="..."> or <form>, with the whole opening tag on one line`
- `gw-target="NAME" takes a fragment name`
- `a gw-target URL starts with / (or is empty or starts with ? for the page itself)`
- `gw-target here needs a path starting with /` (own-page URL in a layout, `not-found.html` or component)
- `gw-target: a form's method is get or post`
- `gw-target: no page matches URL`
- `gw-target: URL is a route.goose; fragments come from pages`
- `gw-target: app/x/page.html has no {{#fragment NAME}}`
- `gw-target: method="post" needs fn POST( in app/x/page.goose`

**Not checked:**
- Whether an element with `id="NAME"` exists on the page that holds the link; it may be in a layout. At run time a missing target means a normal navigation.
- Form field names.

## 6. Runtime: in `client/gwi.js`, new limit 3,584 bytes

**Decision: fragments go into `gwi.js`.** A second file would cost a second request, which outweighs the 946 bytes. The `gwi.min.js` limit rises from 2,560 to **3,584 bytes**; the measured size is 3,133.

Refactor: the existing catch block and the template-and-morph lines become two shared functions. Then append the fragment code. This is the tested text:

```js
function oops(err) {
  console.error(err);
  dispatchEvent(new CustomEvent("gw:error", { detail: String(err) }));
}
function swap(root, html, force) {
  const tp = D.createElement("template");
  tp.innerHTML = html;
  morph(root, tp.content, force);
}
// in on(): catch (err) { live.set(root, keep); return oops(err); }  …  swap(root, html, force);

function frag(type, sel, attr, form) {
  D.addEventListener(type, async (e) => {
    const el = e.target.closest?.(sel);
    const name = el && el.getAttribute("gw-target"), box = name && D.getElementById(name);
    if (!box || box.closest("[data-component]") || e.defaultPrevented || e.button || e.metaKey || e.ctrlKey || e.shiftKey) return;
    e.preventDefault();
    const url = new URL(el.getAttribute(attr) || "", location.href);
    const data = form && new URLSearchParams(new FormData(el, e.submitter));
    const post = form && /^post$/i.test(el.getAttribute("method"));
    if (data && !post) url.search = data;
    const n = box.gw = -~box.gw;
    box.setAttribute("aria-busy", "true");
    try {
      const r = await fetch(url, { method: post ? "POST" : "GET", body: post ? data : null, headers: { "GW-Fragment": name } });
      if (!r.ok) throw Error("fragment " + name + ": " + r.status + " from " + url.pathname);
      if (r.headers.get("GW-Fragment") != name) return location.assign(r.url);
      const html = await r.text();
      if (box.gw == n) swap(box, html, 1);
    } catch (err) {
      oops(err);
    } finally {
      if (box.gw == n) box.removeAttribute("aria-busy");
    }
  });
}
frag("click", "a[gw-target]", "href");
frag("submit", "form[gw-target]", "action", 1);
```

Behaviour:
- **Listeners are bubble-phase.** Component listeners (capture) run first.
- **Left to the browser:** no element with that id, a target inside a component, an event already prevented, or a modifier key held.
- **Forms** send `application/x-www-form-urlencoded`, including the clicked button's name and value. No file uploads.
- **`force` is 1.** After a swap the server's value wins even in the focused input. That is what clears the add box.
- **Last request per target wins.** `aria-busy="true"` is on the target while a request runs, as a CSS hook.
- **A 2xx reply without the echo** means the server sent another page, such as a redirect to a login page. The runtime navigates to `r.url`.
- **A non-2xx reply or a network failure** leaves the DOM alone and raises `gw:error`.

## 7. Coexistence

- **Trigger inside a component:** allowed, and its URL is checked. `on:submit` together with `gw-target` on one form: the component handler prevents the default, so the fragment fetch does not run. Do not combine them.
- **Target inside a component:** not supported. The runtime leaves the click to the browser.
- **Component inside a fragment region:** gen error in v1. Scripts in swapped HTML do not run, and the component's kept state would go stale.
- **`on:` and `bind:`** exist only in `.gshtml`. Nothing changes.
- **`gw:error`:** fragment failures use the same event. The detail reads like `Error: fragment todo-list: 404 from /nope`.
- **Dev overlay:** unchanged except the title string in `dev_inject`: `component error (click to dismiss)` becomes `page error (click to dismiss)`, since it now also covers fragments.
- **Live reload:** fragment replies carry no dev script (`ctx.fragment`). Whole pages are as before.

## 8. Files

**Created**
- `goose-web/form.goose`
- `goose-web/test/fragments.sh` and `goose-web/test/fragments/` (fixtures)
- `goose-web/examples/shop/app/fragments/page.html` and `page.goose`
- `goose-web/examples/shop/app/fragments/products/page.html` and `page.goose`
- `goose-web/examples/shop/app/fragments/products/[id]/page.html` and `page.goose`

**Changed**
- `goose-web/web.goose`: exactly three places.
  1. `struct Ctx`: one new line directly after `outcome: Outcome,`:
     `fragment: bool = false,   // this reply is a fragment: no dev script`.
     The declared default means `new_ctx` is not touched.
  2. `run_worker`: the line `dev_inject(res, cfg.dev_id);` becomes `if !ctx.fragment { dev_inject(res, cfg.dev_id); }`.
  3. `dev_inject`: the overlay title string and its comment.
- `goose-web/cli/gweb.goose`:
  - `Dir` gains `has_post: bool` and `frags: u8[..600]` (names, space-separated); `scan_dir`'s literal changes to match.
  - `compile_template` and `gen_template` take a kind (page, layout or not-found) in place of `layout: bool`, return the fragment names, and handle the tags and the script tag.
  - `gen()` sets `has_post`, raises the `POST`-without-`load` error, calls `scan_targets` (also on each `.gshtml`, from `gen_components`) and `check_targets`.
  - The runtime copy moves out of `gen_components` into `gen_runtime(dev)`, called when there are components or `uses_fragments`.
  - `gen_page_fn` and `gen_main` change as in section 4.
  - `print_routes`: a page with `POST` shows `GET,POST`; each fragment gets a line `  frag   NAME` with the page's URL and file.
- `goose-web/client/gwi.js`, `client/gwi.min.js` (through `client/build.sh`, which is unchanged).
- `goose-web/README.md`: a "Fragments" section.
- `goose-web/examples/shop/public/css/site.css`: only if the demo needs `.error` and `[aria-busy]` styles. It is a benchmark static file, so if its size changes, update the Next twin's copy. Prefer no change.
- `goose-bench/shop/check_site.py`, `goose-bench/shop/bench_shop.py`.

**Not touched:** `goose-net`, `template.goose`, `static.goose`, `owner.goose`, `cli/component.goose`, `examples/shop/app/todos`, `app/state.goose`, `app/layout.html`.

**Parallel work with cookies**
- In `web.goose` I touch only the three places above. No new section, and nothing in params, query, responses or config.
- If cookies adds `Ctx` fields, they go after `title`; mine is three lines above, so the hunks do not meet.
- If cookies needs `run_worker`, the line I change is the `dev_inject` call only.
- Cookies should not use the file name `form.goose`.
- `check_site.py`: my flag line goes directly after `COMPONENTS = …`, and my block goes directly before `print("bytes per URL:")`. A cookies block should go before the `# Components` comment.
- `bench_shop.py`: I add `--fragments` next to `--components`.
- **Open point for the cookies design:** `load` and `POST` receive no `res`. If cookies gives `load` a way to set a cookie, `POST` must get the same.

## 9. Shop demo

Benchmark pages, `/todos` included, stay byte-identical.

**`/fragments`** — the todo list saved in the state owner.
- `page.goose`:
  - `Props { reply: state::Reply, ok: bool, error: u8[..100], draft: u8[..200] }`.
  - `load` lists the todos.
  - `POST` reads `add`+`title` (trimmed, 1 to 200 bytes; otherwise it sets `error` and `draft`), `done=ID`, `undo=ID` and `remove=ID` through the existing `state::Msg`, then returns `load` with `error` and `draft` set.
- `page.html`:

```html
<h1>Fragments</h1>
<p>This list is saved on the server. Each button posts a form; only the list comes back.</p>
<div id="todo-list">{{#fragment todo-list}}
<form method="post" action="/fragments" gw-target="todo-list">
{{#if props.error.len > 0}}<p class="error">{{ props.error }}</p>{{/if}}
<p><input name="title" value="{{ props.draft }}" placeholder="What needs doing?"> <button name="add" value="1">Add</button></p>
<ul>
{{#for t in props.reply.todos}}
<li>{{#if t.done}}<s>{{ t.title }}</s> <button name="undo" value="{{ t.id }}">Undo</button>{{#else}}{{ t.title }} <button name="done" value="{{ t.id }}">Done</button>{{/if}} <button name="remove" value="{{ t.id }}">Remove</button></li>
{{/for}}
</ul>
</form>
{{/fragment}}</div>
<p>The whole page was rendered with <span id="stamp">{{ props.reply.todos.len }}</span> todos.</p>
<p><a href="/fragments/products">Products with fragments</a></p>
```

**`/fragments/products`**
- `load` reads `cat` from the query (`home`, `office`, `outdoor`, `kitchen`, or empty for all).
- Four links plus "all": `<a href="?cat=home" gw-target="results">`.
- `<tbody id="results">{{#fragment results}}` holds the rows. Each row has `<a href="/fragments/products/{{ p.id }}" gw-target="detail">`.
- An empty `<aside id="detail"></aside>` sits beside the table.

**`/fragments/products/[id]`**
- The product, as on `/products/[id]`, inside `<section id="detail">{{#fragment detail}}…{{/fragment}}</section>`.
- 404 for an unknown id.

## 10. Tests

### `test/fragments.sh`

Same shape as `components.sh`.

1. **An ok project,** built and started as `.gooseweb/server --port P --dev-id 5`. Curl checks:
   - the fragment reply's bytes are a substring of the whole page;
   - the echo header and `no-store` are present;
   - a fragment reply has no `__gweb/id`, while the whole page has it;
   - an unknown name gives the whole page without the echo;
   - a POST fragment and a POST without the header both work;
   - `web::form` decodes `+`, `%26`, `%3C` and UTF-8;
   - `Sec-Fetch-Site: cross-site` gives 403;
   - PUT gives 405 with `Allow: GET, HEAD, POST, OPTIONS`;
   - a 303 from `POST` passes through;
   - a page with `gw-target` has the script tag exactly once per template;
   - a project with no component still serves `/_gw/gwi.js`;
   - a page with no fragment generates the same `pN_html.goose` as before (compare against a stored copy).
2. **Expected failures.** One small project per message in sections 2, 3 and 5, each with an `expect.txt`.
3. **`gweb routes`** shows `GET,POST` and the `frag` lines.

`components.sh` keeps guarding the stale `gwi.min.js` banner.

### `check_site.py --fragments`

`bench_shop.py` passes the flag for goose. `call()` gains a raw form-body option. Checks:
- `/fragments` is 200 with `id="todo-list"`, `gw-target="todo-list"`, the script tag and the layout title.
- With `GW-Fragment: todo-list`: 200, the echo, `no-store`, no `<html`, no `gwi.js`, and a body that is a substring of the whole page.
- With `GW-Fragment: nope`: the whole page, no echo.
- POST `add=1&title=check+%3Cfrag%3E` returns a fragment with `check &lt;frag&gt;`. Then `done=ID` shows `<s>`, and `remove=ID` removes it. `/api/todos` still starts with the three seeds.
- POST with an empty title: `class="error"` and the same number of items.
- POST without the header: the whole page.
- Cross-site POST: 403. PUT: 405.
- `/fragments/products?cat=kitchen` with fragment `results`: 25 rows.
- `/fragments/products/42` with fragment `detail`: product 42's name and no `<html`. `/fragments/products/999`: 404.
- In the components block, the size check becomes 3,584.

### Browser test lines (against `gweb dev`)

- Add a todo: it appears, the page does not reload (`#stamp` unchanged), the input is empty and still focused.
- Enter in the input adds as well.
- Add with only spaces: the error line shows. The next valid add clears it.
- After a spaces-only Enter, typing continues in the same input with no click; the same holds after the next valid add (follow-up 1).
- Done, Undo and Remove each change only the list.
- A category link on `/fragments/products` changes the rows without a reload. Quick view fills `#detail`.
- Meta-click on a category link opens a new tab with the whole page.
- With JavaScript disabled, the same forms and links work as whole-page loads.
- A link whose page lacks the fragment at run time navigates normally.
- Stop the server and click Done: the list is unchanged and the overlay shows a `page error`. A click dismisses it.
- Two fast clicks on different category links leave the rows of the last click.
- An edit to `app/fragments/page.html` reloads the page; fragment replies contain no reload script.
- `/components`: Counter and TodoBox still work.

## 11. Rejected alternatives

- **htmx-style `gw-get` / `gw-post` / `gw-swap` on any element:** more attributes to check, more runtime, and no fallback without JavaScript.
- **Separate `fragment.html` files or routes:** the page and the fragment would duplicate markup, or need a server-side include with its own parameter rules.
- **Partials called from `route.goose`:** flexible, but needs a typed partial convention and gives no automatic whole-page fallback.
- **Client-side extraction of `#NAME` from a whole page:** no server change, but every request renders and ships the layout.
- **Separate fragment name and target id:** two names that can drift; one name can be checked at build time.
- **A separate runtime file:** a second request costs more than 946 bytes.
- **`data-gw-target`:** longer, and only validators care.
- **Append and prepend swaps, history push, input triggers with debounce, out-of-band updates:** each adds runtime and rules. None is needed for v1.
- **Components inside fragments:** needs script activation and state reset after every swap.
- **`gw-target` to a `route.goose` that writes HTML by hand:** the region could not be checked.
- **Detecting fragment replies by content type, or by a missing doctype, for `dev_inject`:** fragile; one `Ctx` field is explicit.
- **`Origin` against `Host` for the cross-site check:** breaks behind proxies that rewrite `Host`.

## 12. Risks

- **Template syntax is about to change (addendum 6).** The tag spelling, the same-line rule and the wildcard detection in the URL check all depend on it. Build after it lands.
- **Morph has no keys.** Removing a list item reuses the following nodes; focus or `<details>` state inside a swapped list can move.
- **The same-line rule is strict.** It is what keeps the DOM and the reply aligned. Relaxing it brings back whole-region replacement.
- **The URL check is strict.**
  - A URL built entirely from an expression (`href="{{ p.url }}"`) is an error.
  - A `{{ }}` segment never matches a literal folder.
  - Target ids, field names and `.gshtml` own-page forms are not checked.
- **Page `POST` is a new surface.**
  - `Sec-Fetch-Site` is absent in old browsers and non-browser clients, and those requests are allowed.
  - Once cookies carry sessions, review whether that is enough.
- **`load` and `POST` have no `res`.** See the cookies point in section 8.
- **A top-level `{{#let}}` does not cross a fragment boundary.** This is a behaviour change only for pages that add fragments.
- **A user typing during a request loses that text** when the reply arrives, because `force` is 1.
- **Form controls named `action` or `method`** are safe, since the runtime reads attributes. File inputs are sent as their file name only.
- **Unverified:** the 303-follow path, non-Chromium browsers, and all gweb-side code.
- **Size:** 3,133 of 3,584 bytes. Any v2 swap mode will need the limit raised again.

Prototype files: `/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-fragments/w/goose-web/client/gwi.js`, `/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-fragments/w/goose-web/form.goose`, `/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-fragments/w/goose-web/web.goose`, and the hand-edited generated code in `/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-fragments/w/goose-web/examples/shop/.gooseweb/`. Nothing outside the scratchpad was written, and nothing was committed.

## Follow-up 1

The focus loss is a demo-template fault, and the fix is to make the error the last child of the input's own `<p>`. I ran that fix in a scratch copy of the shop against main's `gweb` (df2a2a1). No runtime change.

### 1. Focus lost when the error line appears or disappears

**Decision: change the demo template and document an author rule; leave `client/gwi.js` alone.**

**Template change** in `examples/shop/app/fragments/page.html`. Delete the line

```html
{#if props.error.len > 0}<p class="error">{props.error}</p>{/if}
```

and change the input line to

```html
<p><input name="title" value="{props.draft}" placeholder="What needs doing?"> <button name="add" value="1">Add</button>{#if props.error.len > 0} <span class="error">{props.error}</span>{/if}</p>
```

The error is now the last child of its parent, so showing or hiding it only appends or removes one trailing node. No sibling shifts.

**Verified in the browser** (Chromium pane, scratch copy, production build on port 3392, script-driven clicks rather than real keystrokes):
- **Spaces-only add:** the error shows; the input is the same element and still has focus; the `<ul>` is the same element.
- **Next valid add:** the error is gone; same input, still focused and empty; same `<ul>`; the item is added.

**Existing checks:** `check_site.py` line 258 looks for `class="error"`, which the `<span>` still satisfies. I did not rerun `check_site.py` or `fragments.sh` against the changed template; rerun both after the edit.

**Author rule** (add to the README "Fragments" section, and it applies equally to components):

> The morph matches sibling nodes by position; it has no keys. An element that comes and goes must be the last child of its parent, or always be rendered and left empty (or `hidden`) when unused. Otherwise every later sibling is rebuilt, and a focused input among them loses focus.

**Browser test line to add:** after a spaces-only Enter, typing continues in the same input with no click; the same holds after the next valid add.

**Rejected:**
- **Keyed morph (match by `id` or a `gw-key`):** it needs lookahead in `morph`, adds bytes for every page, and changes component behaviour that the parity suite and browser lines already cover. Revisit only if list reordering becomes a requirement.
- **A one-step lookahead on `nodeName`:** it would not have caught this case, because both siblings are `<p>`.
- **Always rendering an empty `<p class="error">`:** it works, but leaves an empty styled block on the page; the trailing `<span>` needs no CSS.
- **A build-time warning for a conditional element before siblings:** gweb does not parse HTML structure, so it would be guesswork.

### 2. Builder interpretations

- **1. Messages carry the real name, URL or path: confirmed.** `NAME`, `URL` and `app/x/…` in the design are placeholders, as in `gw-target: no page matches /zzz`.
- **3. Script tag placement: confirmed.** First output with no newline in `page.html` and `not-found.html`; right before `F();` in a layout.
- **6. The `id="NAME"` check: make it stricter.** The match must be at an attribute boundary: the byte before `id="NAME"` is a space or a tab.
  - `data-id="a"` and `xid="a"` no longer satisfy it.
  - The message is unchanged.
  - Still double quotes only, and still a literal name.
  - Add one expected-failure fixture to `test/fragments.sh`: `<div data-id="a">{#fragment a}` must fail with the existing message.

### 3. Recorded, no change

- **Network failure text:** the overlay shows `TypeError: Failed to fetch` without the fragment name. That is the browser's own error passed through `oops`. Adding the name would cost bytes for a dev-only nicety, so it stays.
- **Syntax:** Addendum 4's examples read in Addendum 6 syntax as `{#fragment NAME}`, `{/fragment}`, `{expr}`. The rules in sections 2 and 5 are otherwise unchanged; a wildcard URL segment is one containing `{`.

**Files the builder touches for this follow-up:**
- `goose-web/examples/shop/app/fragments/page.html` (the two-line edit)
- `goose-web/cli/gweb.goose` (the boundary test beside the `id="NAME"` substring check, near line 475)
- `goose-web/test/fragments.sh` plus one fixture
- `goose-web/README.md` (the author rule)

Scratch copy with the tested template: `/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-fragments/f1/shop/app/fragments/page.html`. Nothing outside the scratchpad was written.
