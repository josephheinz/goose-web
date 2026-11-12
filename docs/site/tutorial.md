# Tutorial: a notes app

You will build a small notes app. It has a page, a layout, a JSON route,
shared state, a form that adds notes without a page reload, and a
component that counts characters.

The finished app is in [`tutorial/notes/`](tutorial/notes/). Every block below
with a bold file name matches that file exactly, unless its label says
"step". Run the check with `test/tutorial.sh`.

You need `gweb` and the Goose compiler. See [install](install.md).

## 1. A new project

```
gweb new notes && cd notes
GOOSE=/path/to/goose gweb dev
```

Open <http://localhost:60053>. `gweb dev` rebuilds and restarts on every
change. The starter has a home page, a hello page, a time route and a
404 page. Delete everything under `app/`; the steps below write it again.

## 2. A layout

A `layout.html` wraps every page in its folder and below. `@slot()` marks
where the page goes. `ctx.title` is set by the page's `load`.

**app/layout.html**

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{ctx.title}</title>
<link rel="stylesheet" href="/site.css">
</head>
<body>
<nav><a href="/">Notes</a> <a href="/api/notes">JSON</a></nav>
<main>
@slot()
</main>
</body>
</html>
```

Replace `public/site.css` too. Files in `public/` are served as they are.

**public/site.css**

```css
body { font-family: system-ui, sans-serif; max-width: 40rem; margin: 2rem auto; }
nav a { margin-right: 1rem; }
.error { color: #b00020; }
```

More: [routing](routing.md), [templates](templates.md).

## 3. Shared state

The notes must live somewhere all workers can see. `app/state.goose` is
owned by the main thread. Workers send it a `Msg` and get a `Reply`.
`handle` runs one message at a time, so it needs no locks.

**app/state.goose**

```goose
import std;

struct Note { id: i64, text: u8[..200] }
struct Msg { add: bool, text: u8[..200] }
struct Reply { notes: Note[] }

var notes: Note[>..<];
var next_id = 1;

// Runs on the main thread, one message at a time.
fn handle(msg: const Msg&) -> Reply {
    if msg.add {
        notes.push(Note { id: next_id, text: msg.text });
        next_id += 1;
    }
    return Reply { notes: notes[..] };
}
```

`gweb` adds the namespace. Do not write one. The names `Msg`, `Reply` and
`handle` are required. Notes are lost when the server stops. To keep them,
see [state and SQLite](state-and-sqlite.md).

## 4. A JSON route

A `route.goose` answers one URL with plain handlers. `state::ask` sends a
message to the owner and returns the reply and a success flag.

**app/api/notes/route.goose**

```goose
import std;
import net.http;
import web;
import json;

fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    let reply, ok = state::ask(ctx, state::Msg { add: false, text: "" });
    if !ok { http::json_error(res, http::Status.ServiceUnavailable, "state unavailable"); return; }
    web::json(res, http::Status.Ok);
    res.body.push('[');
    for n, i in reply.notes {
        if i > 0 { res.body.push(','); }
        res.body.push('{');
        json::format_key(res.body, "id");
        format(res.body, n.id, ",");
        json::format_key(res.body, "text");
        json::format_string(res.body, n.text);
        res.body.push('}');
    }
    res.body.push(']');
}
```

Try it: `curl localhost:60053/api/notes` prints `[]`.

## 5. A page with `load`

A page is a `page.html` and an optional `page.goose`. `load` runs first
and returns `Props`. The template reads them as `props`.

**app/page.goose, step 5**

```goose
import std;
import net.http;
import web;

struct Props { reply: state::Reply }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    ctx.title.append("Notes");
    let reply, ok = state::ask(ctx, state::Msg { add: false, text: "" });
    if !ok { return Props { .. }; }
    return Props { reply: reply };
}
```

**app/page.html, step 5**

```html
<h1>Notes</h1>
<ul>
{#for n in props.reply.notes}
<li>{n.text}</li>
{/for}
</ul>
```

`{n.text}` is HTML-escaped. The page title is "Notes", from `ctx.title`.

## 6. A form, CSRF and a fragment

Add a form. Every page `fn POST` needs a CSRF token, so the form holds
`@web::csrf_field(ctx)`. A form with `gw-target="notes"` posts in the
background. The server answers with only the `{#fragment notes}` region,
and the browser swaps it in. Without JavaScript the form still works: it
posts and gets the whole page.

**app/page.goose, step 6**

```goose
import std;
import net.http;
import web;
import web.form;

struct Props { reply: state::Reply, error: u8[..100] }

// Sends one message to the owner. An unreachable owner gives an empty reply.
fn ask(ctx: web::Ctx&, msg: state::Msg) -> state::Reply {
    let reply, ok = state::ask(ctx, msg);
    if !ok { return state::Reply { .. }; }
    return reply;
}

fn page(ctx: web::Ctx&, reply: state::Reply) -> Props {
    ctx.title.append("Notes");
    return Props { reply: reply, error: "" };
}

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    return page(ctx, ask(ctx, state::Msg { add: false, text: "" }));
}

fn POST(req: const http::Request&, ctx: web::Ctx&) -> Props {
    var text: u8[>..] = [];
    web::form(req, "text", text);
    let t = trim(text);
    if t.len == 0 || t.len > 200 {
        var p = load(req, ctx);
        p.error.append("A note is 1 to 200 bytes.");
        return p;
    }
    var msg = state::Msg { add: true, text: "" };
    msg.text.append(t);
    return page(ctx, ask(ctx, msg));
}
```

**app/page.html, step 6**

```html
<h1>Notes</h1>
<form method="post" action="/" gw-target="notes">@web::csrf_field(ctx)
<input name="text" maxlength="200" placeholder="A note">
<button>Add</button>
</form>
<div id="notes">{#fragment notes}
{#if props.error.len > 0}<p class="error">{props.error}</p>{/if}
<ul>
{#for n in props.reply.notes}
<li gw-key="{n.id}">{n.text}</li>
{/for}
</ul>
{/fragment}</div>
```

Rules that matter here:

- `{#fragment notes}` goes right after the opening tag with `id="notes"`,
  and `{/fragment}` right before its closing tag.
- `gw-key` on each list item keeps the right element when the list changes.
- `fn POST` runs in place of `load` for a POST and returns the props.
  A POST without the `GW-Fragment` header gets the whole page, status 200.
- A request with no token gets 403.

More: [fragments](fragments.md), [forms and CSRF](forms-and-csrf.md).

## 7. A component

A component runs in the browser. It is a Goose subset in
`components/Name.gshtml`. This one keeps the text of the input and shows
its length.

**components/CharCount.gshtml**

```html
<script goose>
struct State { text: u8[..200] }
fn test_typed(s: State&) { s.text = "hello"; }
</script>
<input name="text" maxlength="200" placeholder="A note" bind:value="text">
<small>{s.text.len} / 200</small>
```

`bind:value="text"` ties the input to the `text` field of `State`. The
`test_typed` function is run by `gweb test`, as Goose and as JavaScript, and
both must give the same result.

Now the page uses it. `page.goose` imports `CharCount` and puts its
state in `Props`. In `page.goose` change these lines:

**app/page.goose: lines changed**

```goose
import CharCount;
struct Props { reply: state::Reply, counter: CharCount::State, error: u8[..100] }
    return Props { reply: reply, counter: CharCount::State { text: "" }, error: "" };
```

In `page.html` replace the `<input>` line:

**app/page.html: lines changed**

```html
<div>@CharCount(props.counter)</div>
```

A component cannot sit inside a fragment, so it is in the form, outside
`#notes`. More: [components](components.md).

## 8. The finished app

The full files are in [`tutorial/notes/`](tutorial/notes/). `app/page.goose` and `app/page.html` are the step 6 files with the changes of step 7:

**app/page.goose**

```goose
import std;
import net.http;
import web;
import web.form;
import CharCount;

struct Props { reply: state::Reply, counter: CharCount::State, error: u8[..100] }

// Sends one message to the owner. An unreachable owner gives an empty reply.
fn ask(ctx: web::Ctx&, msg: state::Msg) -> state::Reply {
    let reply, ok = state::ask(ctx, msg);
    if !ok { return state::Reply { .. }; }
    return reply;
}

fn page(ctx: web::Ctx&, reply: state::Reply) -> Props {
    ctx.title.append("Notes");
    return Props { reply: reply, counter: CharCount::State { text: "" }, error: "" };
}

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    return page(ctx, ask(ctx, state::Msg { add: false, text: "" }));
}

fn POST(req: const http::Request&, ctx: web::Ctx&) -> Props {
    var text: u8[>..] = [];
    web::form(req, "text", text);
    let t = trim(text);
    if t.len == 0 || t.len > 200 {
        var p = load(req, ctx);
        p.error.append("A note is 1 to 200 bytes.");
        return p;
    }
    var msg = state::Msg { add: true, text: "" };
    msg.text.append(t);
    return page(ctx, ask(ctx, msg));
}
```

**app/page.html**

```html
<h1>Notes</h1>
<form method="post" action="/" gw-target="notes">@web::csrf_field(ctx)
<div>@CharCount(props.counter)</div>
<button>Add</button>
</form>
<div id="notes">{#fragment notes}
{#if props.error.len > 0}<p class="error">{props.error}</p>{/if}
<ul>
{#for n in props.reply.notes}
<li gw-key="{n.id}">{n.text}</li>
{/for}
</ul>
{/fragment}</div>
```

Build it and run the checks:

```
gweb -C docs/site/tutorial/notes build
test/tutorial.sh
```

## Where next

Read the guides in the [index](README.md). For the full rules, read the
[README](../../README.md).
