<!-- Produced by goose-architect on claude-opus-5-5 (medium) -->
# Addendum 14: forms, uploads and errors (goose-web v0.3.0)

## Summary

- **Validation.** A struct whose name ends in `Form`, in `page.goose` or `route.goose`, is a form schema. gweb generates `decode(req, ctx, f, errs) -> bool` for it. Field types are the rules: `u8[..N]` is text of at most N bytes, `i64` a whole number, `bool` a checkbox, `web::Upload` a file. A field with no default is required. Extra rules are plain Goose calls (`web::check_email`, `web::check_range`, `web::add_error`). Errors live in `web::FieldErrors`, which the page keeps in its `Props` and shows with `@web::field_error(props.errs, "email")`. `web::unprocessable(ctx)` makes the reply a 422, and `gwi.js` morphs a 422 fragment reply instead of refusing it.
- **Uploads.** goose-net's loop learns one new trick: a `multipart/form-data` body over 64 KiB goes to a spool file as it arrives, with its own limit (`--max-upload`, default 32 MiB). goose-web parses multipart bodies, from memory or from the spool file, into an urlencoded body of the text fields plus up to 8 files on disk. So `web::form`, `web::csrf_ok` and existing `fn POST` code work unchanged on multipart posts. `web::save_upload` moves a file into place; every unsaved file is deleted after the response. A page or route may declare `const MAX_UPLOAD = N;`.
- **Errors.** `error.html` in any app folder is the error page for the pages below it. It renders inside the layouts above it and sees `err: web::ErrorInfo`. Two paths reach it. `web::fail(ctx, status, message)` is a deliberate error. A crash (bounds error, failed `guard`, any abort) used to leave the client hanging. Now the supervisor answers the request that was in flight, with the error page rendered in a contained thread. Route handlers get a JSON error instead. In `gweb dev` the error page carries the abort text and the source lines around each mapped location, shown in the existing overlay. Build errors in the overlay also get source lines.
- **`loading.html`.** A template in any app folder. Pages below it carry it as `<template id="gw-loading">`. `gwi.js` shows it inside a `gw-target` box when a fragment link takes longer than 150 ms, and inside a form's box when the form opts in with `gw-loading`. Streaming a loading state on first page load waits for streaming responses (open question 2).
- **Component error boundaries** are designed here (section 6) but not built: they belong in the new update model of Addendum 12, which does not exist yet.

## What I read, and the evidence

Read: `docs/BACKLOG.md`, `ARCHITECTURE.md`, `DESIGN.md`, Addenda 1 to 11 (headings and the parts that touch forms, `Ctx`, the dispatcher and the dev loop; 7, 8 and 11 in full), `web.goose`, `form.goose`, `template.goose`, `csrf.goose`, `src/sys.c`, `src/owner.c`, `client/gwi.js`, `cli/gweb.goose` (scan, `gen`, `gen_page_fn`, `gen_route_fn`, `gen_finish`, `gen_dispatch`, `gen_main`, `rewrite_errors`, `dev`, `server_cmd`), the test scripts, `goose-net/http.goose`, `net.goose` and `src/loop.c`.

Facts the design rests on:

1. **The whole body is buffered.** `gnet_loop_next` frames a request by `Content-Length` and hands over head and body in one buffer; a body over `max_request` (goose-web's `--max-body`, default 1 MiB) is `EV_TOO_LARGE`, answered 413 by `run_worker`. Chunked bodies are refused. There is no way today to accept a 20 MB image, or to keep one out of memory.
2. **`Request` is views into the raw buffer.** `req.body` is a slice, so goose-web can point a copy of the request at another buffer (`var r = req; r.body = other;`). That is how the multipart text fields reach unchanged code.
3. **`web::form` splits `req.body` on `&`.** `csrf_ok` reads `_csrf` through it. A multipart post therefore fails CSRF today.
4. **A crash kills the worker thread, not the request.** The generated `supervisor` respawns a `thread_spawn_contained` worker and prints `why`. The connection that was being served gets no reply, and the dead loop's other connections leak until the client gives up (DESIGN §5 lists this as a risk). There is no per-call `try` in Goose that I can see in any of the three repos, so a crash cannot be caught inside the worker.
5. **`thread_wait` returns `why`, the abort text.** I could not see whether it carries `file:line`. That decides how good the dev error page is (experiment E1).
6. **Templates keep line identity** (`.gooseweb/pN_html.goose:N` is `app/.../page.html:N`) and `.gooseweb/map.txt` maps each generated file to its source. The dev server runs from the project folder (`./.gooseweb/server`), so it can read `map.txt` and the sources at run time.
7. **`gwi.js` refuses any non-2xx fragment reply** (`if (!r.ok) throw`), and it sends forms as `URLSearchParams`, which drops files. `gwi.min.js` is 3,604 bytes against the 4,096-byte budget.
8. **Pages already have the shape forms need.** `fn POST(req, ctx) -> Props` renders the same template as `load`, the template sees `req` and `ctx`, and `@ns::f(a)` calls any `fn f(out, a)`.
9. **gweb already scans user Goose for conventions** (`defines`, `csrf_const`, `mentions_csrf`) and copies `page.goose` / `route.goose` to `.gooseweb/<ns>.goose`. Text appended after the last line keeps every user line number.
10. **No reflection.** Nothing in the repos walks struct fields at run time; `component.goose` parses a Goose subset at build time. A typed decoder must be generated.

Not verified (no `goose` on this machine): everything that needs the compiler. In particular E1 (the content of `why`), E2 (a bounded array of structs, `Upload[..8]`, as a `Ctx` field with a default), E3 (a `@web::f(...)` call inside a start tag), and E4 (`thread_spawn_contained` with a second thread function in the generated `main.goose`). Each build step names the experiment it depends on and the fallback.

## 1. Validation

### D1. The schema is a Goose struct named `*Form`

```goose
// app/signup/page.goose
struct SignupForm {
    email: u8[..200],
    name: u8[..80],
    age: i64,
    newsletter: bool,
    note: u8[..500] = "",       // optional: it has a default
}
```

| Field type | Form value | Error when |
|---|---|---|
| `u8[..N]` | the URL-decoded text, as typed (not trimmed) | longer than N bytes: "Use at most N characters." |
| `i64` | `parse_int(trim(v))` | not a whole number: "Enter a whole number." |
| `bool` | true when the field is present and not `""`, `"off"`, `"false"` or `"0"` | never |
| `web::Upload` | a file part (section 2) | a text value or an empty file part where a file is required |

- **Required** = no `= default`. A required text or number field that is absent or blank after `trim` gets "Required." A `bool` is never required (an unticked box sends nothing). An optional field that is absent or blank keeps its default.
- Any other field type is a gweb build error at the field's line: `form fields are u8[..N], i64, bool or web::Upload`. `f64`, enums and repeated fields (multi-select) are left out of v1: `f64` because I cannot see a float parser in std from here, enums because gweb would have to parse the enum too. Users decode those by hand with `web::form`.
- The HTML `name` is the Goose field name.
- Structs in `lib/` get no decoder (lib is symlinked, not copied). A page imports the struct from lib and calls the `web::form_*` helpers itself, or declares the form struct in its own `page.goose`.

**Generated code.** gweb appends to the copied `.gooseweb/<ns>.goose`, after the user's last line:

```goose
// gweb: form decoders (generated)
fn decode(req: const http::Request&, ctx: const web::Ctx&, f: SignupForm&, errs: web::FieldErrors&) -> bool {
    let before = errs.n;
    web::form_text(req, "email", f.email, errs, true);
    web::form_text(req, "name", f.name, errs, true);
    web::form_int(req, "age", f.age, errs, true);
    web::form_bool(req, "newsletter", f.newsletter);
    web::form_text(req, "note", f.note, errs, false);
    return errs.n == before;
}
```

One `decode` overload per form struct in the file. The helpers do the work, so they are unit-tested without gweb and usable by hand. If the user's file already defines `fn decode(`, gweb reports a build error (`fn decode is generated for SignupForm; rename yours`).

**Why.** The types already say the length, the kind and whether a value is required, so there is no annotation language to learn. Generated code stays three lines per field. The `Form` suffix follows the gweb habit of naming conventions (`load`, `POST`, `const CSRF`).

**Rejected.**
- Rules in comments (`// @email @min 3`): a second language inside comments, unchecked by the compiler.
- A runtime schema table (`web::Rule[]` with field names): it cannot write into typed fields without reflection.
- A marker such as `@form struct`: `.goose` files must stay plain Goose for the compiler and editors.

### D2. Errors

```goose
struct FieldError { field: u8[..64], message: u8[..200] }
struct FieldErrors { n: i64, items: FieldError[16], dropped: bool }   // the first error per field is kept
fn no_errors() -> FieldErrors
fn add_error(errs: FieldErrors&, field: const u8[:], message: const u8[:]) -> bool   // false: already has one, or full
fn has_errors(errs: const FieldErrors&) -> bool
fn error_for(errs: const FieldErrors&, field: const u8[:]) -> const u8[:]          // "" for none; field "" = the form
fn check_length(errs: FieldErrors&, field: const u8[:], v: const u8[:], min: i64, max: i64) -> bool
fn check_range(errs: FieldErrors&, field: const u8[:], v: i64, min: i64, max: i64) -> bool
fn check_email(errs: FieldErrors&, field: const u8[:], v: const u8[:]) -> bool    // one @, text both sides, a dot after it, no space
fn check_one_of(errs: FieldErrors&, field: const u8[:], v: const u8[:], options: const u8[:][:]) -> bool
fn errors_json(res: http::Response&, errs: const FieldErrors&)   // 422 {"errors":{"email":"Required."}} for route.goose
```

A check on a field that already has an error does nothing and returns false, so a "Required." is not followed by "Enter a valid email.".

### D3. Showing errors and values in the template

| Call | Writes |
|---|---|
| `@web::field_error(props.errs, "email")` | `<span class="gw-error" id="email-error">Required.</span>`, or nothing |
| `@web::invalid(props.errs, "email")` | ` aria-invalid="true" aria-describedby="email-error"` inside the input's tag, or nothing |
| `@web::field_value(req, "email", props.user.email)` | the posted value, escaped, on a POST that sent the field; otherwise the fallback, escaped |
| `{web::error_for(props.errs, "")}` | the form-level message, if any |

`field_value` shows exactly what was typed, so a bad `age` of `abc` comes back as `abc`, not `0`. On a GET it shows the fallback, which serves edit forms.

The morph rule of ARCHITECTURE §4.4 applies: an error `<span>` that comes and goes must be the last child of its parent, or keyed. The docs example puts each one at the end of its field's `<p>`, as the fragments demo does.

### D4. Status: 422, and `gwi.js` accepts it

`Ctx` gets `status: i64 = 0`. `web::set_status(ctx, code)` sets it and `web::unprocessable(ctx)` sets 422. The generated page function applies it after rendering, when the outcome is still `Continue`. `gwi.js` treats a 422 reply that echoes `GW-Fragment` like a 200, so the form with its errors is morphed in. Without JavaScript the browser shows the 422 page normally.

**Why.** 422 is the honest status, keeps form failures out of success metrics and caches, and is what Turbo expects. **Rejected:** answering 200 (simpler, but every log and monitor reads a failed signup as a success).

### D5. The page code

```goose
struct Props { form: SignupForm, errs: web::FieldErrors }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    return Props { form: SignupForm { .. }, errs: web::no_errors() };
}

fn POST(req: const http::Request&, ctx: web::Ctx&) -> Props {
    var p = load(req, ctx);
    if !decode(req, ctx, p.form, p.errs) || !web::check_email(p.errs, "email", p.form.email) {
        web::unprocessable(ctx);
        return p;
    }
    // save p.form ...
    web::redirect(ctx, "/signup/thanks", 303);
    return p;
}
```

## 2. File uploads

### D6. goose-net spools large multipart bodies to disk

New in `net.goose` and `src/loop.c`, off unless called:

```goose
// Multipart bodies may be up to max_upload bytes; one over spool_over bytes is written to a new file in dir as it
// arrives and handed over as Event.Spooled. False when dir cannot be used.
fn set_uploads(l: Loop, max_upload: i64, spool_over: i64, dir: const u8[:]) -> bool
// The file of the last Event.Spooled; the caller owns it from then on and must delete it.
fn spool_path(l: Loop, out: u8[>..]&)
enum Event { Request, TooLarge, HeadTooLarge, Unsupported, BadLength, Failed,
             Spooled,        // out holds the head through its blank line; the body is in spool_path
             SpoolFailed }   // the spool file could not be written; answer 500 and close
```

- `frame()` reads `Content-Type` beside `Content-Length` in `scan_head`. For `multipart/form-data` the limit is `max_upload`; for anything else it stays `max_request`.
- When the head is complete, the body is multipart, the length is over `spool_over` and a dir is set, the connection enters spool mode: `open(dir/gnet-<pid>-<n>, O_CREAT|O_EXCL|O_WRONLY, 0600)`, buffered body bytes are written, and each later `fill` writes what belongs to the body to the file and keeps any pipelined bytes in the buffer.
- A connection dropped or timed out mid-body unlinks its file. `gnet_loop_free` unlinks files of connections still spooling.
- Without `set_uploads`, behaviour is byte-for-byte today's, so `http::serve` users and the examples see nothing new.

**Why in goose-net.** Only the loop sees the bytes as they arrive; above it the body already exists in memory. The change is generic HTTP ("big uploads go to disk"), with nothing multipart-specific beyond reading one header.

**Rejected.**
- Raising `--max-body` to 32 MiB: every connection could then hold 32 MiB in memory.
- Parsing multipart inside the loop and writing each file part directly: puts a form parser into the network library, in C.
- A per-route limit inside the loop: the loop cannot see routes. Per-route limits are checked by goose-web after dispatch (D9), so a client may still send up to `--max-upload` before the 413.

### D7. goose-web turns multipart into a plain form plus files

`Config` gains `max_upload` (default 33,554,432; `--max-upload N`), `spool_over` (65,536; not a flag) and `upload_dir` (`.gooseweb.uploads`; `--upload-dir D`). `run_worker` calls `set_uploads` once, and at start-up deletes files left in `upload_dir` by an earlier run (names starting `gnet-` or `gw-`). One server per upload dir is documented.

`Ctx` gains `spool: u8[..256] = ""` (set by `run_worker` for `Event.Spooled`) and `uploads: Upload[..8]` (E2; fallback: a separate `web::Files` value made in `run_worker` and reached through `ctx.worker`, see step 3).

```goose
struct Upload {
    field: u8[..64],
    filename: u8[..128],       // as the client sent it, control bytes removed; never a path to trust
    content_type: u8[..96],    // as the client sent it
    size: i64,
    path: u8[..256]            // the temp file; "" when no file was sent
}

fn is_multipart(req: const http::Request&) -> bool
// Parses the body (req.body, or ctx.spool when set). Text fields go into body, urlencoded, in order;
// file parts go to temp files listed in ctx.uploads. False after writing 400 or 413.
fn multipart_begin(req: const http::Request&, ctx: Ctx&, res: http::Response&, body: u8[>..]&) -> bool
fn form_upload(ctx: const Ctx&, field: const u8[:], out: Upload&, errs: FieldErrors&, required: bool) -> bool
fn save_upload(up: const Upload&, dest: const u8[:]) -> bool   // no overwrite; rename, or copy across file systems
fn safe_name(out: u8[>..]&, filename: const u8[:])            // basename, [A-Za-z0-9._-], no leading dot, <= 100 bytes
fn sniff(up: const Upload&) -> const u8[:]                    // "image/png", "image/jpeg", "image/gif", "image/webp", "application/pdf" or ""
fn check_upload(errs: FieldErrors&, field: const u8[:], up: const Upload&, max_bytes: i64, types: const u8[:][:]) -> bool  // types checked with sniff
```

- **Parser.** One implementation over a window reader: in memory it reads the slice, on disk it reads 64 KiB windows through `src/upload.c` (`pread`). Boundary search keeps a tail of boundary length between windows. File parts are copied to `upload_dir/gw-<pid>-<worker>-<n>` with `O_EXCL`, mode 0600.
- **Limits.** At most 64 parts, 8 files, 64 KiB per text field, 16 KiB of part headers, and the total body limit from D6. A part without `name`, a missing final boundary or any other malformed input is a 400 with "malformed multipart body". A ninth file is a 413.
- **Why the synthetic body.** `web::form`, `form_int`, `csrf_ok` and every existing `fn POST` read `req.body` as urlencoded. Giving them the text fields in that form makes multipart transparent, with no second API and no change to `csrf.goose`. Files are found by field name in `ctx.uploads`, never by a value in the body, so an urlencoded post cannot point `form_upload` at a server file.
- **Cleanup.** After `send_response`, `run_worker` unlinks `ctx.spool` and every `ctx.uploads[i].path`. A saved file is gone from its temp path already, so its unlink fails harmlessly.
- **Content type.** `content_type` and the filename are client claims. `check_upload` checks the sniffed type, so `image/png` means the bytes start like a PNG. SVG is not sniffed as an image, on purpose: it can carry script.

### D8. `gwi.js` sends files

A `gw-target` form with `enctype="multipart/form-data"` is sent as `FormData`, not `URLSearchParams`. About 30 bytes.

### D9. Where the generator calls it

For a page with `fn POST`, and for a route with POST, PUT or PATCH, the generated function becomes:

```goose
fn page_3(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    match req.method { ... }                           // as today
    if p3_x::MAX_UPLOAD > 0 && web::content_length(req) > p3_x::MAX_UPLOAD { web::fail(ctx, 413, "The upload is too large."); return; }   // only with const MAX_UPLOAD
    var mp: u8[>..] = [];
    var r = req;
    if web::is_multipart(req) { if !web::multipart_begin(req, ctx, res, mp) { return; } r.body = mp; }
    if !web::csrf_ok(r, res) { return; }
    ... the rest as today, with r in place of req ...
}
```

`const MAX_UPLOAD = N;` is found like `const CSRF` (a line starting `const MAX_UPLOAD`), in `page.goose` or `route.goose`.

## 3. Error pages

### D10. `error.html`, nearest wins

- Any app folder may hold `error.html`. A page or route uses the one in its own folder or the nearest folder above it.
- It compiles to `fn render(out: u8[>..]&, req: const http::Request&, ctx: const web::Ctx&, err: const web::ErrorInfo&)`. No fragments, no `@slot()`. Components are allowed.
- It renders inside the layouts **above its own folder**, not those of the failing page below it (Next.js's rule: the error boundary sits inside its segment's layout).
- Without any `error.html`, a page error is a small built-in HTML page (`<h1>500 Internal Server Error</h1>` and the error id).
- Errors of `route.goose` handlers are JSON: `{"error":"<message>","id":"<id>"}`.
- `not-found.html` stays the 404 page. `web::fail(ctx, 404, ...)` is allowed and uses `error.html`; `web::not_found` uses `not-found.html` as today.

```goose
struct ErrorInfo {
    status: i64,
    message: u8[..512],    // web::fail's message; "Internal Server Error" for a crash
    id: u8[..16],          // 8 random bytes in hex, also in the server log line
    crashed: bool,
    detail: u8[..4096]     // dev only: the abort text and source lines; "" in production
}
```

### D11. Deliberate errors: `web::fail`

`Outcome` gains `Error`. `web::fail(ctx, status, message)` sets it, with `ctx.error_status` and `ctx.error_message: u8[..512]`. Like `not_found`, the loader returns `Props { .. }` and the generated code skips rendering. `finish` gets an `Error` arm that calls the generated `error_reply(ctx.route, req, ctx, res)`. The dispatcher stores the matched dir index in `ctx.route: i64 = -1` before calling the page or route function, so `finish` knows which `error.html` is nearest. The `Error` arm logs `goose-web: error <id>: <status> <method> <target>: <message>`.

### D12. Crashes: the supervisor answers the request

A small C table, `src/inflight.c`, one entry per worker slot: the connection fd, the loop handle, the matched route, a phase flag, and a copy of the request head (at most 8 KiB, cut at a line end).

1. `run_worker` registers its loop handle once, then per request `inflight_begin(slot, fd, head)` before dispatch and `inflight_end(slot)` after the send. The dispatcher's `ctx.route` store also calls `inflight_route(slot, i)`. Cost: one memcpy of the head per request. Build step 5 measures it against the plaintext benchmark; over 2% is a stop-and-ask.
2. When `thread_wait` reports an abort and the slot has a request in flight, the supervisor stores `why` in the slot and runs `thread_fn crash_reply(slot, cfg, attempt)` contained. It re-parses the saved head into a `Request` (no body), makes a fresh `Ctx`, builds `ErrorInfo { status: 500, crashed: true, .. }` and calls the generated `error_reply`. It sends with `Connection: close`.
   - Attempt 1: the nearest `error.html` with its layouts.
   - Attempt 2, if attempt 1 aborts: the same `error.html` without layouts.
   - If attempt 2 aborts, or there is no `error.html`: a fixed plain-text 500, written by C straight to the fd.
   - A crash during a `web::fail` render (phase flag set) starts at attempt 2.
3. Then the supervisor frees the dead loop (`net::free`), which closes the worker's other connections instead of leaking them; clients reconnect. Then it respawns the worker, as today.

Thread-safety rests on `thread_wait`: the worker is dead before the supervisor reads its slot.

**Why.** Goose has no per-call recovery, and per-request threads would cost every request. The crash is rare; making it expensive is fine as long as the common path pays only the head copy.

**Rejected.**
- A contained thread per request: a spawn per request.
- Letting the client time out (today): a hung tab, and the leaked loop.
- Rendering the error page in the supervisor without containment: a crash in `error.html` would then kill the supervisor and stop that worker slot for good.

**Risk.** The other connections of the crashed worker are closed. Requests already read from them are lost and get no reply; a browser retries idempotent ones. Open question 6.

### D13. The dev error page

In `gweb dev` (`cfg.dev_id != 0`):
- `ErrorInfo.detail` holds: method and target, the abort text, then for up to 3 `path:line` locations found in it, the source path from `.gooseweb/map.txt` and 5 lines around it with the line marked `>`. Page and layout templates map line for line; component lines go through the `// gw:line` tag as `component_lines_back` does.
- The reply carries `<script type="application/json" id="gw-dev-error">"<detail>"</script>` (JSON-escaped and `<`-safe through `json_text`) before the dev script. The dev script reads it on load and shows it in the existing overlay as `server error (click to dismiss)`. A click shows the app's own error page under it.
- `web::fail` errors fill `detail` with method, target and message only.
- If E1 shows that `why` has no location in a normal build but has one with `--debug`, `gweb dev` builds with `--debug`. If neither has one, the page shows the abort text and request without source lines, and the CHANGELOG says so.
- Build errors: `gweb dev` appends the same 5-line excerpt after each `path:line:` error line (at most 5) when it writes `.gooseweb.dev/errors.txt`. The overlay already shows that file.

In production `detail` is always empty; the abort text goes only to the log line with the error id.


### D14. A page `fn POST` may end the reply itself (added after review)

Found by the auth-security architect: a page `fn POST(req, ctx) -> Props` has no `res`, so a 429 or a custom 500 it wants cannot stop the page render. Two changes:
- `Outcome` gains `Done`. `web::done(ctx)` sets it. The generated code skips rendering, and `finish` leaves `res` as the handler wrote it.
- `fn POST` and `fn load` in `page.goose` may take a third parameter, `res: http::Response&`. gweb sees `http::Response` in the `fn POST(` or `fn load(` line and passes `res`. Without `res`, `web::fail(ctx, 429, "...")` already ends the reply with the error page (D11).

**Why.** `fail` covers the common case through `error.html`; `Done` covers a handler that writes its own body or headers (a `Retry-After`, a JSON reply to a fetch). **Rejected:** making every loader take `res`, which breaks every existing page.

## 4. `loading.html`

- Any app folder may hold `loading.html`, compiled to `fn render(out, req, ctx)` (no props, no fragments, no `@slot()`).
- A whole-page render of a page at or below it appends `<template id="gw-loading">…</template>` after the page's own markup, inside the innermost layout. Fragment replies leave it out.
- `gwi.js`, in the fragment listener: for a link, or for a form that has a `gw-loading` attribute, it starts a 150 ms timer. If the reply has not arrived, it saves the box's children and fills the box with the template's content. The template is `gw-loading="id"` when given, else `#gw-loading`; `gw-loading="none"` turns it off for a link. A reply morphs over it as usual. On a failure the saved children come back, so a half-filled form is not lost. About 200 bytes minified.

**Why client-side.** goose-web renders a page in one piece, so there is no moment on first load when a loading state could show without streaming. Fragment navigation is where users wait today. The same template serves client navigation (Backlog 8) later.

**Rejected.**
- Streaming the layout and `loading.html` first, then the page: needs chunked responses, which belong to the streaming work. Open question 2.
- Loading UI for every form submit by default: a form usually should stay visible while it posts.

## 5. Files and edit regions

| File | Repo | Steps | Change |
|---|---|---|---|
| `src/loop.c`, `net.goose`, `test/spool_test.c`, `test/spool.sh` | goose-net | 1 | spool mode, `set_uploads`, `spool_path`, two events |
| `valid.goose` (new, `namespace web;`), `test/valid_test.goose` | goose-web | 2 | D2, D3 helpers, `form_text/int/bool`, `errors_json`, `set_status`, `unprocessable` |
| `web.goose` | goose-web | 2, 3, 5 | `Ctx` fields `status`, `spool`, `uploads`, `route`, `error_status`, `error_message`; `Outcome.Error`; `Config` fields and flags; `run_worker` (Spooled, cleanup, inflight calls); dev script reads `gw-dev-error` |
| `upload.goose` (new), `src/upload.c` (new), `web.build`, `test/upload_test.goose`, `test/upload_c_test.c` | goose-web | 3 | D7 |
| `errors.goose` (new), `src/inflight.c` (new), `test/inflight_c_test.c` | goose-web | 5 | `ErrorInfo`, `fail`, crash helpers, dev detail |
| `cli/gweb.goose` | goose-web | 4, 5, 6, 7 | form scan and decoders, `MAX_UPLOAD`, multipart prelude; `error.html`, `error_reply`, `finish`, supervisor; `loading.html`; dev excerpts |
| `client/gwi.js`, `client/gwi.min.js`, `test/frag_test.mjs` (new), `test/frag.sh` (new) | goose-web | 6 | 422, FormData, loading |
| `test/forms/`, `test/forms.sh`, `test/errors/`, `test/errors.sh` | goose-web | 4, 5 | sites and curl suites |
| `README.md`, `docs/ARCHITECTURE.md`, `CHANGELOG.md`, `test/release_check.sh` | goose-web | 8 | docs, release check runs the new suites |

Shared with other architects: `Ctx` and `Config` in `web.goose` (auth-security will likely add session fields; add fields at the end of the struct, each with a default), the generated `supervisor` (operations: graceful shutdown), and `gwi.js` (reactivity: my changes stay inside `frag()`).

## 6. Component error boundaries (design only; build after Addendum 12)

Today a throwing handler or render rolls the state back, leaves the DOM alone and dispatches `gw:error`. With the Addendum 12 update model, a throw can come midway through patching, so the DOM may be half-updated. Proposal, to be checked against Addendum 12:
- A component template may hold one top-level `{#catch}…{/catch}` block. The server never renders it.
- On a throw in a handler, a watch or an update: restore the state copy, then re-render the whole component from it (one morph). If that throws too, replace the component's children with the `{#catch}` markup, set `data-gw-failed`, and stop routing its events. `gw:error` fires either way.
- A server render that crashes is a page crash (D12); a component cannot catch it, because Goose cannot catch.

Rejected: an `@error` handler function in `<script goose>` (more API for the same outcome), and server-side boundaries (they need per-call recovery).

## 7. Experiments

- **E1** `why` content: a page that indexes past an array's end, built normally and with `--debug`; record the text `thread_wait` gives. Decides D13's source lines and whether `gweb dev` uses `--debug`.
- **E2** `uploads: Upload[..8]` as a defaulted `Ctx` field (`= []`). Fallback in step 3.
- **E3** `<input name="age"@web::invalid(props.errs, "age")>` compiles through the template compiler. Fallback: `{#if web::error_for(...).len > 0} aria-invalid="true"{/if}` in the docs, and drop `invalid`.
- **E4** a second contained `thread_fn` in `main.goose` with `(slot: i64, cfg: web::Config, attempt: i64)`.

## 8. Build plan

Every step: work only in the named worktree; commit locally, never push. Find `goose` through `$GOOSE`, then `PATH`. Without it, write the code and tests anyway, run what runs without it (`cc`, `node`, `sh -n`), and say which tests did not run.

### Step 1: goose-net spool mode (worktree `goose-net/.worktrees/forms-errors`)
- Files: `src/loop.c`, `net.goose`, new `test/spool_test.c` (a C harness with a stub `goose.h`: `gs_rref` and `gs_bld_append` over a malloc buffer, plus a socketpair client), new `test/spool.sh` (`cc` it and run it), `CHANGELOG.md` (Unreleased).
- Tests, in C: a small multipart post is `EV_REQUEST` as before; one over `spool_over` is `EV_SPOOLED` with the head in `out` and the exact body bytes in the file; a non-multipart body over `max_request` is still `EV_TOO_LARGE`; a multipart body over `max_upload` is `EV_TOO_LARGE`; a pipelined second request after a spooled body is framed correctly; a client closing mid-body leaves no file; no `set_uploads` gives today's behaviour; an unwritable dir makes `set_uploads` return false.
- Done: `test/spool.sh` passes; `net.goose` has `set_uploads`, `spool_path`, `Spooled`, `SpoolFailed`; behaviour without `set_uploads` unchanged.

### Step 2: validation runtime (goose-web; can run beside step 1)
- Files: new `valid.goose`; `web.goose` (`Ctx.status`, `set_status`, `unprocessable`); new `test/valid_test.goose` in the `cookie_test.goose` style.
- Tests: `form_text` (present, absent, blank required, blank optional keeps default, over capacity, `+` and `%XX` decoding); `form_int` (" 42 ", "4x", "", optional); `form_bool` (absent, "on", "off", "0", "", "1"); `add_error` (first per field kept, 17th sets `dropped`); `error_for`; each `check_*` including "skip when the field already has an error"; `check_email` accepts `a@b.co`, refuses `a@b`, `@b.co`, `a b@c.d`, `a@@b.c`; `field_error`, `invalid`, `field_value` output, escaping included; `errors_json` body and status.
- Done: the test file is complete; it passes under goose, or is marked untested.

### Step 3: uploads runtime (goose-web; after step 1)
- Files: new `upload.goose`, new `src/upload.c` (pread window, append write, `O_EXCL` create, link-or-copy save, unlink, dir sweep), `web.build`, `web.goose` (`Config` fields and `--max-upload`, `--upload-dir`; `Ctx.spool`, `Ctx.uploads`; `run_worker`: `set_uploads`, the sweep, `Spooled` and `SpoolFailed`, cleanup after send). New `test/upload_test.goose`, new `test/upload_c_test.c` and `test/upload_c.sh`.
- E2 fallback: if a struct array cannot be a `Ctx` field, keep the uploads in a `web::Files` value declared in `run_worker` next to `ctx`, and pass it to `multipart_begin` and `form_upload`; record that in the build log, because step 4's generated calls change.
- Tests: parse in memory and from a spool file (the same fixtures both ways): text fields become the urlencoded body in order, `_csrf` included; files land with the right bytes and size; a boundary that straddles a 64 KiB window; CRLF inside file data; quoted and unquoted `name`/`filename`; limits (65th part, 9th file, 64 KiB text field) and malformed bodies; `safe_name` cases (`../../etc/passwd`, `.htaccess`, unicode, 300 bytes); `sniff` for each type and for SVG; `save_upload` refuses an existing dest and works across a rename; cleanup removes unsaved files.
- Done: C tests pass; Goose tests written (run if goose exists).

### Step 4: generator for forms (goose-web; after steps 2 and 3)
- Files: `cli/gweb.goose`: scan `struct <Name>Form {` in page and route copies (fields may span lines; skip comments), validate field types with errors at the field's line, append decoders, report a user `fn decode(`; `const MAX_UPLOAD` detection; the multipart prelude and `r` in `gen_page_fn` and `gen_route_fn`; apply `ctx.status` after render. New `test/forms/site` (signup page with `SignupForm`, a fragment form, an upload page with `const MAX_UPLOAD = 200000`, an upload route) and `test/forms.sh` (curl: required errors and 422; values come back; valid post redirects 303; fragment POST with errors returns 422 with the `GW-Fragment` echo; multipart with `_csrf` passes CSRF; file saved; over `MAX_UPLOAD` is 413; over `--max-upload` is 413; temp dir empty after each request; build errors for a bad field type and for a user `fn decode`).
- Done: generated code for the test site reads like D1 and D9; `forms.sh` passes under goose, or is marked untested; `gweb` itself builds under goose, or is marked unbuilt.

### Step 5: error pages and crash replies (goose-web; after step 4)
- Files: new `errors.goose` (`ErrorInfo`, `fail`, error id, dev detail builder, default page, JSON error); new `src/inflight.c`; `web.build`; `web.goose` (`Outcome.Error`, `Ctx.route`, `error_status`, `error_message`, inflight calls in `run_worker`, the dev script reads `gw-dev-error`); `cli/gweb.goose` (scan `error.html` in any folder, `K_ERROR` with no fragments or slot, `error_reply` choosing the nearest file and its layouts, the `finish` arm, `ctx.route` and `inflight_route` in the dispatcher, the `crash_reply` thread and the new supervisor body). New `test/errors/site` (pages that `fail` with 503, that index out of bounds, a crash inside a nested folder with its own `error.html`, a crashing layout, a crashing `error.html`, an API route that crashes) and `test/errors.sh`; new `test/inflight_c_test.c`.
- Tests: each case's status, body and `Connection: close`; the next request on a new connection succeeds (worker respawned); nested `error.html` wins; a crashing layout falls back to attempt 2; a crashing `error.html` gives the plain 500; API errors are JSON; with `--dev-id` the reply has `gw-dev-error` with a source excerpt (if E1 allows), without it no detail; the log line has the id. Benchmark: plaintext requests per second before and after, on the same machine.
- Done: tests pass under goose, or are marked untested; the benchmark result is in the build log (or marked not run).

### Step 5b: `Outcome.Done` and `res` for page handlers (goose-web; after step 5)
- Files: `web.goose` (`Outcome.Done`, `web::done`), `cli/gweb.goose` (detect `http::Response` in the `fn POST(` / `fn load(` line, pass `res`; skip render on `Done`; `finish` arm), `test/errors/site` (a page POST that writes a 429 with `Retry-After` and calls `done`), `test/errors.sh`.
- Done: generated code passes `res` only where declared; tests written; untested without goose.

### Step 6: `loading.html` and `gwi.js` (goose-web; `gwi.js` part can run beside step 3)
- Files: `client/gwi.js` (422, FormData for multipart forms, loading), `client/gwi.min.js` via `client/build.sh`; `cli/gweb.goose` (scan `loading.html`, compile it, append the template in the whole-page render); new `test/frag_test.mjs` and `test/frag.sh` (jsdom, with `fetch` stubbed: 422 with echo morphs; 500 does not; multipart form sends `FormData`; a reply in 50 ms shows no loading; 300 ms shows it then the reply; a failure restores the old children; `gw-loading="none"`; a form without `gw-loading` shows none).
- Done: `frag.sh` and `test/morph.sh` pass (node is on this machine); `gwi.min.js` under 4,096 bytes and its banner hash current; the gweb part tested under goose or marked untested.

### Step 7: build-error excerpts in `gweb dev` (goose-web)
- Files: `cli/gweb.goose` (`write_dev_errors` adds excerpts). Test: a case in `test/errors.sh` with a type error in `page.html` whose errors.txt shows the marked line.
- Done: as above, or marked untested.

### Step 8: docs (goose-web)
- `README.md` (forms, uploads, error pages, loading), `docs/ARCHITECTURE.md` (sections 3, 4.3 and 7), `CHANGELOG.md` (Unreleased: the new files, flags, 422, the closing of a crashed worker's connections), `test/release_check.sh` (runs `forms.sh`, `errors.sh`, `frag.sh`, `upload_c.sh`).

## 9. Risks

- **No compiler here.** Steps 2 to 5 and 7 may land untested. The generator steps are the riskiest: a wrong generated line breaks every app's build. The next session with `goose` must run all suites before a release.
- **`Ctx` grows** by about 5 KB (mostly `uploads`). It is a stack value per request. If E2 or the benchmark objects, the `web::Files` fallback removes most of it.
- **Merge friction** on `web.goose` (`Ctx`, `Config`, `run_worker`), the generated supervisor, and `gwi.js` with the reactivity, auth-security and operations branches.
- **Disk.** Uploads count against the disk of `upload_dir`; no quota beyond `--max-upload` per request.

## 10. Open questions for the user

1. **422 or 200 for a form with errors?** Default: 422, with `gwi.js` morphing 422 fragment replies.
2. **`loading.html` on first page load needs streaming.** Default: v1 shows it only for fragment requests; first-load streaming waits for the streaming work.
3. **Component error boundaries** wait for Addendum 12. Default: design only (section 6), built after reactivity lands.
4. **Upload defaults.** Default: 32 MiB per request, spool over 64 KiB, 8 files, temp dir `.gooseweb.uploads/` in the project folder.
5. **Text fields are not trimmed.** Default: kept as typed; "Required." checks the trimmed value. Trimming would also trim passwords.
6. **A crash closes the crashed worker's other keep-alive connections.** Default: yes; the alternative is today's leak.
7. **`error.html` per folder, rendered in the layouts above it.** Default: yes, nearest wins, like Next.js.
