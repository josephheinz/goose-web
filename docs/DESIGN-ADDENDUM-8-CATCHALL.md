<!-- Produced by goose-architect on claude-opus-5-5 (medium) -->
# Addendum 8: catch-all routes (goose-web v0.2.0)

## Summary

- A folder named `[...name]` matches one or more trailing path segments. A folder named `[[...name]]` matches zero or more.
- `public/` files are tried first for GET and HEAD. After them come routes, ranked per segment: literal, then `[id]`, then catch-all.
- `web::param(ctx, "name")` returns the matched tail as raw path text, without decoding, for example `a/b/c`. An optional catch-all with no segments gives `""`.
- The tail is at most 1,024 bytes and may have any number of segments. A tail with an empty, `.` or `..` segment gets a 404, and so does one that percent-decodes to such a segment, to a `/` or `\`, or to a control byte.
- The dispatcher keeps its `match n` on segment count. Each arm also lists the catch-alls that fit, in rank order, and a new arm `17` handles deeper paths. Apps without catch-alls generate the same arms as today, plus one change: the static-file block moves to the top.

## What I verified, and what I did not

Verified by reading:
- `cli/gweb.goose`: `scan_dir`, `scan`, `slug`, `route_before`, `dispatch_order`, `match_url`, `check_targets`, `gen_dispatch`, `gen_static` and `print_routes`.
- `web.goose`: `Params`, `set_param`, `param`, `split`, `run_worker`. The 308 for a trailing slash runs before dispatch.
- `goose-net/http.goose`: `parse_request` splits the target at `?` and does not normalize the path. `MAX_HEAD` is 65,536 and `url_decode` turns `+` into a space.

From the stopped prototype, which was built in its scratchpad and not in the lab:
- A `set_rest` and `path_decode` close to the ones below compiled. Its unit test passed 40 of 40 checks. That version kept the fields in `Ctx`; this design moves them to `Params`.
- A bounded-array field with a default (`u8[..1024] = ""`) compiles. A constructor may leave that field out.
- Inside `namespace web`, the name `split` resolves to `web::split`, which hides the std one, and `std::split` is not a valid name. Code in `web.goose` that splits on `/` must scan the bytes itself.
- The prototype's gweb edits were never built, so the dispatcher half has not been compiled. The builder's step 3 is the first build of it.

Not verified: the cost of the larger `Params` per request (experiment E1), and that namespaces like `p7_docs____path` raise no problem in practice. The grammar allows them: the spec defines identifiers as `[A-Za-z_][A-Za-z0-9_]*`.

## 1. Syntax

**Choice.** Both forms are included:

| Folder | Matches | Example `app/docs/...` |
|---|---|---|
| `[...name]` | 1 or more trailing segments | `/docs/a`, `/docs/a/b`; not `/docs` |
| `[[...name]]` | 0 or more trailing segments | `/docs`, `/docs/a`, `/docs/a/b` |

Rules:
- `name` must pass `is_ident`, as for `[id]`.
- A catch-all folder is the last segment of its route. Any subfolder of it is a build error, except `_x` and `.x` folders, which are ignored as today.
- `layout.html` and `middleware.goose` inside a catch-all folder work as anywhere else.
- A folder holds at most one catch-all child.
- `[[...name]]` is a build error when its parent folder has `page.html` or `route.goose`, because both would answer the parent URL.
- The catch-all's name must differ from every `[x]` name earlier in the same path.
- A route or page folder is at most 16 segments deep, catch-all included. Today a deeper folder is silently never matched. This becomes a build error for every route.

**Why.** These are Next.js names, so users already know them. `[[...name]]` lets one page serve both `/docs` and `/docs/a/b` with one template, which is what the CMS-STUDY R2 page tree needs at a root like `app/[[...path]]`. It costs one comparison in `dispatch_order` and one build error.

**Rejected.**
- Only `[...name]`: `/docs` would need a second page that duplicates the template.
- A `*` or `[*]` folder: not Next-like, and `*` in folder names is awkward in shells.
- Catch-alls in the middle of a path (`/a/[...x]/edit`): this needs backtracking in the dispatcher, and Next.js forbids it too.

## 2. Precedence

**Choice.** This is the order for a request with `n` segments:

1. **`public/` files, for GET and HEAD.** The existing `static_file` block moves to the top of `dispatch`, emitted only when `statics.len > 0`. A static URL equal to a literal route URL is still a build error (`scan`), so a public file can only win over `[id]` and catch-all routes.
2. **Routes in the arm for `n`, in rank order.** Rank each folder segment: literal 0, `[name]` 1, catch-all 2. `route_before(a, b)` compares the ranks segment by segment over `min(len a, len b)` segments. The first segment that differs decides, and the lower rank goes first. If all are equal, the result is false, so the sorted path order stands. For routes without catch-alls this is today's `route_before`, unchanged.
3. **First candidate whose literal segments match wins, with no fallthrough.** The candidate then sets its params. If a param or the tail is refused, the answer is 404, as today when an `[id]` value is over 256 bytes.
4. **Otherwise 404** through `finish`.

Examples, with `blog/new`, `blog/[id]`, `blog/[...rest]`, `shop/[cat]/[...rest]` and a root `[...all]`:

| Path | Winner |
|---|---|
| `/blog` | `[...all]` (both blog routes need 2 segments or more) |
| `/blog/new`, `/blog/7` | `blog/new`, `blog/[id]` |
| `/blog/7/comments`, `/blog/new/x` | `blog/[...rest]` |
| `/blog/logo.txt` with `public/blog/logo.txt` | the static file (today `blog/[id]` would shadow it) |
| `POST /blog/logo.txt` | `blog/[id]` |
| `/shop/tools` | `[...all]`; `/shop/tools/a` goes to `shop/[cat]/[...rest]` |

**Why.**
- Statics first is the "static-file order fix" from CMS-STUDY. Without it, a root catch-all would swallow `/favicon.ico` and the framework's own `/_gw/gwi.js`.
- Literal routes cannot collide with statics, so statics first gives the same result as Next.js's order (literal pages, then public, then dynamic) with one block.
- The extra cost on a normal request is one `match p.len` and, rarely, one string compare.
- Ranking per segment is Next.js's rule. It keeps `a/[...r]` ahead of `[id]/x` for `/a/x`, so catch-alls cannot simply be tried after the `match n`.

**Rejected.**
- Statics last with an exception for catch-alls: `[id]` routes would still shadow public files.
- Backtracking to the next candidate when params are refused: it hides bugs, and today's dispatcher does not do it.
- Catch-alls in one block after the `match`: the order is wrong for `a/[...r]` against `[id]/x`.

**Behaviour change.** In an existing app, a public file that an `[id]` route at the same depth used to shadow is now served for GET and HEAD. The shop has no such case. This goes in the CHANGELOG.

## 3. The value in `load` and handlers

**Choice.** `Params` gets two defaulted fields, and `Ctx` is not touched:

```goose
struct Params { n: i64, names: u8[..32][8], values: u8[..256][8],
                rest_name: u8[..32] = "", rest: u8[..1024] = "" }
```

| API | Behaviour |
|---|---|
| `web::param(ctx, "path")` | The tail, raw and joined with `/`: `a/b%20c/d`. `""` for an optional catch-all with no segments, and `""` when absent. |
| `web::param_int(ctx, "path")` | Works unchanged, since it calls `param`. |
| `web::path_decode(out, s) -> bool` | Appends `s` with `%XX` decoded. `+` stays `+`, because it is a query convention. Returns false and appends nothing on malformed `%`, on a decoded `/`, `\`, byte < 32 or 127, or on a decoded segment that is `.` or `..`. |
| `web::set_rest(ctx, name, rest) -> bool` | Called by the generated dispatcher only. It is public because the dispatcher lives in the generated namespace. |

Segments are split by the user with `split(web::param(ctx, "path"), '/')` (std `split`, visible in app namespaces).

**Why.**
- The `Params` fields leave `Ctx` alone. Addendum 7 is likely to add a field there, so this keeps the two designs apart.
- Defaults leave `no_params()` and `new_ctx` unchanged.
- One name-based lookup matches Addendum 1, which rejected `param(req, ctx, ...)` offsets.
- Raw text matches `[id]` params, which are also raw.
- A separate 1,024-byte field avoids raising the 256-byte cap of all 8 param values, which would add 6 KB.
- The empty case is `""`. No handler needs to tell "absent" from "zero segments", because the route itself says which catch-all it is.

**Rejected.**
- Storing the tail as an offset into `req.path` with `web::rest(req, ctx)`: no copy and no cap, but a second lookup API. It is the fallback if E1 fails.
- A segments array (`u8[..N][M]`): it fixes a second limit, and the user can split in one line.
- Decoding in `param`: different from `[id]`, and `+` and `%2F` would be ambiguous.
- Raising the `Params.values` cap to 1,024 bytes: 6 KB more per request for every route.

## 4. Limits

| Limit | Value | When exceeded |
|---|---|---|
| Tail bytes (raw) | 1,024 | 404 |
| Tail segments | none beyond the byte cap and `MAX_HEAD` | – |
| Prefix depth (folders before the catch-all) | 15 (route depth 16 including it) | build error |
| Catch-all name | 32 bytes | 404 at run time, as `set_param`; names are identifiers, so this is theoretical |

**Why.**
- 1,024 bytes covers any page tree that people type, and it is the cap of `Ctx.location`.
- The segment count is free. `web::split` returns 17 and fills all 16 `starts` when a path has more than 16 segments. A catch-all whose prefix is at most 15 segments needs only `starts[k]` for `k` at most 15, so arm `17` can serve it.

**Rejected.**
- Keeping the 16-segment limit for catch-alls: an arbitrary 404 on deep trees, and arm `17` costs a few lines.
- 4,096 bytes: 3 KB more `Ctx` per request on every route, for paths nobody types.

## 5. Generated dispatcher

**Choice.**
- `dispatch_order(count, order)` changes. A route without a catch-all is a candidate when `seg_count(rel) == count`. A catch-all route with prefix length `k = seg_count(rel) - 1` is a candidate when `count >= k + 1` for `[...]`, or `count >= k` for `[[...]]`. Count `17` means "17 or more", and the same formula works for it.
- Insertion is the existing first-fit with the new `route_before`.
- `gen_dispatch` emits arms for `count` in `0..=17` that have candidates.
- For a catch-all candidate, the literal conditions and `set_param` terms for segments `0..k-1` are generated exactly as today. Then `web::set_rest(ctx, "NAME", TAIL)` is appended as the last `&&` term of the params expression. `TAIL` is `req.path[starts[k]..]` when `count > k`, and `""` when `count == k`. The body shape is today's: `if PARAMS { CALL } else { web::not_found(ctx); } finish(req, ctx, res); return -1;`.

Shape for `/blog/...` in arm 3 (illustrative):

```goose
        3 => {
            if seg[0] == "shop" { if web::set_param(ctx, "cat", seg[1]) && web::set_rest(ctx, "rest", req.path[starts[2]..]) { route_9(req, ctx, res); } else { web::not_found(ctx); } finish(req, ctx, res); return -1; }   // /shop/[cat]/[...rest]
            if seg[0] == "blog" { if web::set_rest(ctx, "rest", req.path[starts[1]..]) { route_4(req, ctx, res); } else { web::not_found(ctx); } finish(req, ctx, res); return -1; }   // /blog/[...rest]
            { if web::set_rest(ctx, "all", req.path[starts[0]..]) { route_1(req, ctx, res); } else { web::not_found(ctx); } finish(req, ctx, res); return -1; }   // /[...all]
        },
```

The top of `dispatch`, when there are statics:

```goose
    if req.method == http::Method.Get || req.method == http::Method.Head {
        let i, hit = static_file(req, res);
        if hit { return i; }
    }
    var seg: const u8[:][16] = [""; 16];
    ...
```

The bottom becomes `web::not_found(ctx); finish(req, ctx, res); return -1;`.

**Why.**
- Normal routes keep their per-count arms and literal tests. Catch-alls only add leaves to the arms where they fit.
- A root catch-all repeats its leaf in up to 18 arms. That is code size, not time.

**Rejected.**
- A trie or a separate matcher for catch-alls: more generator code for no speed gain at these route counts.
- Using `seg[k..n]` joined at run time: it costs a copy, and `req.path[starts[k]..]` is already the joined text.

## 6. Build-time gw-target check and `gweb routes`

**Choice.**
- `match_url(url)` counts the URL's segments as today. When there are more than 16, it looks up candidates with `count = 17` instead of returning -1.
- For a catch-all candidate, only segments `0..k-1` are compared, by today's rules: a literal fits an equal literal or `[name]`, and a `{expr}` wildcard fits only `[name]`. Segments from `k` on always fit, literal or `{expr}`.
- So `/docs`, `/docs/a/b` and `/docs/{p.slug}` all resolve to `app/docs/[[...path]]`, and the fragment and POST checks then run against that page as for any page.
- `gweb routes` is unchanged. `url_of(rel)` already prints `/docs/[[...path]]` and `/[...all]`. The routes suite checks this.

**Why.** The check must use the dispatcher's order. Reusing `dispatch_order` gives that for free.

**Rejected.**
- Skipping the check for catch-all URLs: it loses the fragment-name check, which is the useful part.
- Listing routes in dispatch order in `gweb routes`: it changes existing output, and nobody asked for it.

## 7. Decoding and `..` safety

**Choice.**
- `set_rest` refuses the tail, so the request gets a 404, when:
  - the tail is over 1,024 bytes;
  - a `/`-separated raw segment is empty, as in `a//b`;
  - `path_decode` of the whole tail returns false.
- So the matched tail never holds a raw or percent-encoded `.` or `..` segment, a `%2F`, a `\` (raw or `%5C`), or a control byte.
- An empty tail is valid, for `[[...]]` only.
- The 308 for a trailing slash in `run_worker` already removes the `a/` case for GET and HEAD. For other methods, a trailing slash makes an empty last segment, and that gets a 404.
- The value stays raw. A handler that maps it to a file or a key decodes it once with `web::path_decode`, which cannot fail on a value that passed `set_rest`.
- `http::url_decode` is also safe on it: `+` becomes a space, nothing worse.
- `path_decode` and the segment scan go through the bytes by hand (see the `split` finding). One helper, `dot_segment(s) -> bool`, serves both.

**Why.** Goose-net passes the path through without normalizing it. Validating in `set_rest` means every catch-all handler is safe without the user's help, including one that naively joins the tail to a directory. The cost is one pass over at most 1,024 bytes, on catch-all requests only.

**Rejected.**
- Leaving validation to the user: CMS and file-serving catch-alls are exactly where traversal bugs happen.
- Normalizing (resolving `..`) instead of refusing: it changes which page answers, and Next.js does not do it either.
- Accepting `%2F` inside a segment, as Next.js does: then the decoded tail no longer splits into its segments.

**Risk.** `[id]` params are not given the same validation. They are single segments, so a decoded `..` in one is still a hazard when it is joined to a path. That is outside this addendum, and the README warns about it.

## 8. Shop demo

**Choice.** A new page, `app/docs/[[...path]]/page.goose` with `page.html`. No existing file changes, the layout's nav is not touched, and no benchmark page links to it, so `/products/42` stays byte-identical.

- `page.goose` holds a small table of 4 entries:
  - `""`: Docs
  - `guide`: Guide
  - `guide/routes`: Routes
  - `guide/routes/catch-all`: Catch-all routes
- `load`:
  1. Reads `web::param(ctx, "path")` and decodes it with `web::path_decode`.
  2. Finds the entry, and calls `web::not_found(ctx)` when there is none.
  3. Sets `ctx.title`, and returns `Props` with the title, the decoded path and a breadcrumb.
- The breadcrumb is a fixed array of up to 4 `{ href: u8[..1024], label: u8[..64] }` items, built from std `split` on `/`.
- `page.html`:
  - shows the breadcrumb;
  - shows a line with the raw value, `<p class="raw">param: {web::param(ctx, "path")}</p>`;
  - shows `<div id="body">{#fragment body}<h1>{props.title}</h1>…{/fragment}</div>`;
  - shows links to the 4 entries, each `<a href="/docs/guide/routes" gw-target="body">`. These exercise the build-time check through a catch-all.
- Section 10 lists the check_site lines.

**Why.** It covers the empty case, a multi-segment value, decoding, the 404 from a loader, and gw-target through a catch-all. It adds no route at the root, so `/nope` stays a 404.

**Rejected.**
- A root `app/[[...path]]` in the shop: it changes `/nope` and would mix the demo with the benchmark.

## 9. Files and edit regions

| File | Change | Region |
|---|---|---|
| `web.goose` | `Params` gains `rest_name`, `rest` | `struct Params` line, near the top. Do not touch `struct Ctx` or `new_ctx`. |
| `web.goose` | `param` checks `ctx.params.rest_name` after its loop | `fn param` body |
| `web.goose` | new `dot_segment`, `path_decode`, `set_rest` | after `fn param_int`, before `fn query` |
| `cli/gweb.goose` | folder-name parse, catch-all subfolder and sibling errors | `scan_dir`, the `if name[0] == '['` block and the subfolder loop |
| `cli/gweb.goose` | new helpers `seg_kind`, `catch_kind`, `prefix_len` | beside `seg_count` |
| `cli/gweb.goose` | `[[...]]` beside a parent page, duplicate name, depth over 16 | `scan()`, after the public-collision loop |
| `cli/gweb.goose` | ranks | `route_before` |
| `cli/gweb.goose` | candidates | `dispatch_order` |
| `cli/gweb.goose` | catch-all prefix and count 17 | `match_url` |
| `cli/gweb.goose` | statics first, arm 17, `set_rest` term | `gen_dispatch` only |
| `test/catchall_test.goose` | new: unit checks | – |
| `test/catchall.sh`, `test/catchall/site/**` | new: integration suite | – |
| `test/release_check.sh` | two `step` lines | after `step fragments ...`; append only |
| `examples/shop/app/docs/[[...path]]/page.{goose,html}` | new | – |
| `goose-bench/shop/check_site.py` | `--catchall` flag | docstring paragraph after `--fragments`; `CATCHALL = ...` after `FRAGMENTS = ...`; a block before `print("bytes per URL:")`; one list term in the bytes loop |
| `README.md` | the `[id]` paragraph under Project layout; a new `## Catch-all routes` section between `## Signatures` and `## Templates` | do not edit the Helpers paragraph (Addendum 7 territory) |
| `CHANGELOG.md` | bullets under `## Unreleased` (create it above `## v0.1.1` if absent) | own bullets only |

Not touched:
- `form.goose`, `template.goose`, `owner.goose`, `client/gwi.js` and goose-sqlite.
- These functions in `cli/gweb.goose`: `gen_page_fn`, `gen_route_fn`, `gen_main`, `gen_static`, `scan_targets` and `print_routes`.
- `VERSION`: the bump to 0.2.0 is the release step, outside this plan.

## 10. Tests

**Unit, `test/catchall_test.goose`** (modelled on `cookie_test.goose`, and built by `release_check.sh` the same way):
- `new_ctx` has empty `rest_name` and `rest`, and `param` gives `""`.
- After `set_rest(ctx, "path", "a/b/c")`, `param` gives `a/b/c`. Another name gives `""`. A `set_param` value still resolves.
- An empty tail is accepted and gives `""`.
- Refused: `a//b`, `/a`, `a/`, `a/./b`, `a/../b`, `..`, `%2e%2e/x`, `a/%2E`, `a%2Fb`, `a%5Cb`, `%00`, `%1f`, `%7F`, `%zz`, `%4` and `%`.
- Accepted: `a/.b/..c/...` and `caf%C3%A9`.
- A tail of 1,024 bytes passes and one of 1,025 fails. A name of 32 bytes passes and one of 33 fails.
- `path_decode`:
  - `a%20b` gives `a b`;
  - `a+b` gives `a+b`;
  - `caf%C3%A9` gives 5 bytes;
  - the empty string and `a/b` are accepted;
  - nothing is appended on a refusal.

**Integration, `test/catchall.sh`** (shaped like `fragments.sh`, port `${PORT:-3994}`, `curl --path-as-is`). The site `test/catchall/site` has:
- `app/page.html`: `home`.
- `app/not-found.html`.
- `app/docs/[[...path]]/page.html` with `page.goose`: prints `docs:[{web::param(ctx, "path")}]`, and has a `{#fragment body}`.
- `app/blog/new/route.goose`: `blog-new`.
- `app/blog/[id]/route.goose`: `blog-id:ID`.
- `app/blog/[...rest]/route.goose`: `blog-rest:REST`.
- `app/shop/[cat]/[...rest]/route.goose`: `shop:CAT:REST`.
- `app/[...all]/route.goose`: GET and POST, `all:ALL`.
- `public/favicon.ico`, `public/css/site.css` and `public/blog/logo.txt`.

| Request | Expect |
|---|---|
| `/` | 200 `home` |
| `/docs`, `/docs/a`, `/docs/a/b/c` | `docs:[]`, `docs:[a]`, `docs:[a/b/c]` |
| `/docs/caf%C3%A9` | 200 `docs:[caf%C3%A9]` |
| `/docs/a//b`, `/docs/a/../b`, `/docs/a/./b`, `/docs/%2e%2e/x`, `/docs/a%2Fb`, `/docs/a%5Cb` | 404, not-found page |
| `GET /docs/a/` | 308, `Location: /docs/a` |
| `/blog`, `/shop`, `/shop/tools`, `/x/y/z` | `all:blog`, `all:shop`, `all:shop/tools`, `all:x/y/z` |
| `/blog/new`, `/blog/7` | `blog-new`, `blog-id:7` |
| `/blog/7/comments`, `/blog/new/x` | `blog-rest:7/comments`, `blog-rest:new/x` |
| `/shop/tools/a/b` | `shop:tools:a/b` |
| `/favicon.ico`, `/css/site.css`, `/blog/logo.txt` | the file bytes (cmp), with an ETag |
| `POST /favicon.ico` | `all:favicon.ico` |
| `HEAD /blog/7` | 200, empty body |
| 17 and 40 segments `/a/a/…` | `all:a/a/…` |
| `/blog/` followed by 300 `x` | 404 (the `[id]` cap; no fallthrough) |
| `/docs/` with a 1,024-byte tail, then a 1,025-byte tail | 200, then 404 |

Build errors, each in a copy of the site, checking that `gweb build` fails with the message at its path:
- `app/docs/[[...path]]/more/page.html`: `a catch-all folder is the last segment of its route; move this folder out of it`
- `app/blog/[...x]/route.goose` beside `[...rest]`: `a folder holds one catch-all folder at most`
- `app/docs/page.html`: `app/docs/[[...path]] and app/docs both answer /docs; use [...path] or remove one`
- `app/u/[id]/[...id]/route.goose`: `the catch-all name id is already a parameter of this path`
- Folders `[..x]`, `[...9x]`, `[[...x]` and `[[x]]`: `a dynamic segment folder is [name], [...name] or [[...name]], where name is an identifier`
- A page 17 folders deep: `a route is at most 16 folders deep`
- In `app/page.html`, `<a href="/docs/a" gw-target="nope">`: `gw-target: app/docs/[[...path]]/page.html has no {#fragment nope}`. The accepted links `/docs` and `/docs/a/b` with `gw-target="body"` are part of the passing site.

`gweb routes` lists `/docs/[[...path]]`, `/[...all]` with `GET,POST`, and the `frag body` line.

**Shop, `check_site.py --catchall`** (goose-web only):
- `/docs`: 200, `Docs | Goose Shop`, and `param: </p>`.
- `/docs/guide/routes`: 200, `Routes | Goose Shop`, and `param: guide/routes`.
- `/docs/guide/routes/catch-all`: 200.
- `/docs/nope` and `/docs/a/../b`: 404, `Not found`. Send the second with `http.client`, which does not normalize the path.
- `/docs/guide/routes` with a `GW-Fragment: body` header: 200, `Routes` present, and no `<html`.
- Add `/docs` and `/docs/guide/routes` to the bytes list when the flag is on.

**Browser and curl lines for the user:**

```
curl -si http://localhost:60053/docs
curl -si http://localhost:60053/docs/guide/routes/catch-all
curl -si --path-as-is http://localhost:60053/docs/a/../b        # 404
curl -si http://localhost:60053/docs/%2e%2e/x                     # 404
curl -s -H 'GW-Fragment: body' http://localhost:60053/docs/guide  # the region only
```

In the browser, open `/docs` under `gweb dev`. Click Guide, then Routes: the body swaps without a full load, and the URL and the breadcrumb update. Reload `/docs/guide/routes` directly and the same page renders.

## 11. Builder plan (Sonnet 5.5, medium)

Work in `/Users/joeheinz/Documents/goose`. Make one commit per step, in the repo that owns the files: goose-web, the shop, or goose-bench.

The **full checks**, which "after each step" refers to:
- `components.sh` 41, `templates.sh` 33, `fragments.sh` 69, `cookie_test` 59.
- goose-net `test_net` 142.
- `test/release_check.sh`.
- Shop:
  1. Rebuild with `gweb build`.
  2. `check_site.py --components --cookies --fragments` passes.
  3. `curl -s /products/42` matches `goose-bench/shop/baseline/products_42.html` (`cmp`).

Every suite must pass at its number or above. Later steps add `catchall_test`, `catchall.sh` and `--catchall`.

Code is self-documenting. Write why-comments only. No comment restates code or names this document.

**Step 0: baseline, no commit.**
1. Build the shop with the current gweb.
2. Run the shop server with `--workers 1`.
3. Run `goose-bench/loadgen/loadgen PORT /products/42 16 20000 keepalive` 5 times, and do the same for `/about`.
4. Record the median requests per second.

**Step 1: runtime (`web.goose`, `test/catchall_test.goose`, `test/release_check.sh`).**
- `Params` fields, then `dot_segment`, `path_decode`, `set_rest`, and the `param` lookup, as sections 3 and 7 describe.
- Use `ascii::hex_value`, as `web.goose` already does. Scan bytes by hand rather than calling `split`.
- Add the unit test, and a `catchall_test` step in `release_check.sh` built like `cookie_test`.
- Checks:
  - `catchall_test` passes with every check from section 10.
  - The full checks.
  - **Experiment E1:**
    1. Rebuild the shop with this `web.goose` (gweb unchanged).
    2. Repeat step 0.
    3. If the median on `/products/42` or `/about` falls more than 3% below baseline, stop and report the numbers. Do not go on to step 2. The design would then switch to the offset fallback in section 3.
    4. At 3% or less, go on.
- Commit: "web: catch-all tail in Params, set_rest and path_decode".

**Step 2: statics first (`cli/gweb.goose`, `gen_dispatch` only).**
- Move the GET/HEAD `static_file` block to the top of `dispatch`, emitted only when `statics.len > 0`. Leave the bottom as `web::not_found(ctx); finish(...); return -1;`.
- Rebuild gweb with `goose build -o gweb cli/gweb.goose`.
- Checks:
  - The full checks.
  - Inspect `examples/shop/.gooseweb/main.goose`: the static block comes first, and the arms are unchanged otherwise. Diff it against the previous gen to confirm.
- Commit: "gweb: try public files before routes".

**Step 3: scan and errors (`cli/gweb.goose`).**
- `seg_kind(s)`: 0 literal, 1 `[name]`, 2 `[...name]`, 3 `[[...name]]`.
- `catch_kind(rel)`: the kind of the last segment when it is 2 or 3, else 0.
- `prefix_len(rel)`: `seg_count(rel) - 1`.
- `scan_dir`:
  - the new folder-name rule;
  - the error for a subfolder of a catch-all, without scanning it;
  - the error for a second catch-all sibling.
- `scan()`, for every route or page dir:
  - the `[[...]]` beside a parent page or route error;
  - the duplicate-name error;
  - the depth error for more than 16 segments.
- Use the exact messages in section 10.
- Checks:
  - The full checks.
  - Build a scratch site with each bad folder and confirm each message by hand. The suite comes in step 5.
- Commit: "gweb: catch-all folder names and their build errors".

**Step 4: dispatch and URL check (`cli/gweb.goose`).**
- `route_before` with ranks.
- `dispatch_order` with the candidate rule.
- `gen_dispatch`, sections 2 and 5:
  - arms `0..=17`;
  - the `set_rest` term;
  - `TAIL` as `req.path[starts[k]..]` or `""`.
- `match_url`, section 6.
- Checks:
  - The full checks.
  - The shop's generated arms are identical to step 2's (`diff`), since the shop has no catch-alls yet.
  - Build the section 10 site by hand, and spot-check `/docs`, `/blog/7/comments` and `/blog/logo.txt` with curl.
- Commit: "gweb: dispatch catch-all routes".

**Step 5: suite (`test/catchall.sh`, `test/catchall/site/**`, `test/release_check.sh`).**
- Every row and error of section 10, plus the `gweb routes` lines.
- Print `N of N checks passed` as the other suites do.
- Add a `step catchall env PORT="${PORT:-3994}" sh "$HERE/catchall.sh"` line after the fragments step.
- Checks:
  - `catchall.sh` passes and reports its count.
  - `release_check.sh`.
- Commit: "test: catch-all suite".

**Step 6: shop demo (`examples/shop/app/docs/[[...path]]/`, `goose-bench/shop/check_site.py`).**
- Section 8, then the `--catchall` lines from section 10.
- Checks:
  - `check_site.py --components --cookies --fragments --catchall` passes.
  - `/products/42` byte-identical.
  - `curl -s /nope` is still a 404.
  - Run the browser lines in section 10 in the browser pane under `gweb dev`.
- One commit per repo: "shop: /docs catch-all demo" and "check_site: --catchall".

**Step 7: docs (`README.md`, `CHANGELOG.md`).**
- `README.md`:
  - Rewrite the `[id]` paragraph as "A folder named `[id]` is a dynamic segment; `[...slug]` and `[[...slug]]` are catch-alls (see below)."
  - Add `## Catch-all routes`: the two forms, precedence with statics first, `web::param` raw, `web::path_decode`, the limits, the 404 cases, and the `[id]` traversal warning.
- `CHANGELOG.md`: under `## Unreleased`, catch-all routes, statics before dynamic routes (the behaviour change), and `web::path_decode`.
- Checks:
  - The README commands are copy-paste correct (run the two curl lines).
  - `release_check.sh`.
- Commit: "docs: catch-all routes".

**Merge order with Addenda 7, 9 and 10.**
- Step 1 touches `struct Params`, `fn param` and the region between `param_int` and `query`.
- Steps 2 to 4 touch only the `cli/gweb.goose` functions listed in section 9.
- If Addendum 7 lands first and changes `struct Ctx`, step 1 needs no change. If it also edits `fn param`, rebase by hand: the `rest_name` check goes after the loop.

## 12. Risks

- **E1.** `Params` grows by about 1,060 bytes per request. If constructing `Ctx` writes every byte, normal routes slow down. Step 1 measures it, and the offset fallback is ready.
- **Behaviour change from statics first.** Apps whose `[id]` routes shadowed public files now serve the file for GET and HEAD.
- **No fallthrough.** A catch-all does not catch what a more specific route refused. For example, `/blog/<300 bytes>` gets a 404 from `blog/[id]` instead of reaching `blog/[...rest]`. This is documented, and it is consistent with today.
- **`%2F` and encoded dot segments get a 404.** A CMS whose slugs contain encoded slashes cannot use them. This is deliberate.
- **Generated code size.** A root catch-all repeats one leaf in up to 18 arms.
- **Namespace slugs** like `p7_docs____path` are legal identifiers. Only error messages show them, and they are ugly there.
- **Dynamic `{expr}` URLs in gw-target** are checked by shape only. A run-time value with `/` in it can reach another route than the check found, as today with `[id]`.

## 13. Decisions for the user

1. **Include `[[...name]]`.** I chose yes.
2. **Statics before dynamic routes for all apps.** This is a behaviour change for an `[id]` route that shadowed a public file. I chose yes, with a CHANGELOG entry.
3. **A 404 for `%2F`, encoded dot segments, backslashes and control bytes in a catch-all tail.** Next.js would decode `%2F` into the segment instead. I chose refusal.
4. **The 1,024-byte tail cap,** against a larger cap or the offset form with no cap.
5. **The shop demo at `/docs`, reachable only by URL** (no nav link, so the benchmark bytes stay the same), with a separate `--catchall` flag in `check_site.py`.
6. **When to bump `VERSION` to 0.2.0 and tag.** This is not in this plan, and Addenda 7, 9 and 10 land in the same release.
7. **E1 regression threshold.** I set 3%. Raise or lower it.
