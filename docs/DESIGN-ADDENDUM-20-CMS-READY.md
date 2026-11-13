# Addendum 20: ready for a CMS package

Addendum 19 built the CMS-facing features. This one proves them together. `test/cmsready/` is a CMS in miniature, as a
fixture: a package installed from git and mounted at `/admin`, a module mounted inside it, and a host app. It is built
the way `goose-cms` will be (D6, D7, D9, D10 and D11 of `docs/CMS-DESIGN.md` on `arch/cms`). `test/cmsready.sh` walks it
over HTTP (110 checks). The guide is `docs/site/building-a-cms.md`.

## What was built

| Item | Where |
|---|---|
| `gweb::send_file`, `FileOptions`, `mime_type`, `file_path_ok` | `http/files.goose`, `src/files.c`, `gweb.build` |
| Git URL sources in `gweb.packages` | `is_url_source`, `url_part_ok`, `fetch_git` in `cli/gweb.goose` |
| Prefixed `validate` errors, JSON after a failed parse | `gen` of `parse` in `cli/views.goose` |
| `Tester.host` | `testing.goose` |
| The fixture and its suite | `test/cmsready/`, `test/cmsready.sh`, `test/files_test.goose` |

## send_file

The CMS design asked for 80 to 120 lines of app code to serve `/media/<key>/<name>`. It is a library function now.

- **Signature.** `send_file(req, ctx, res, root, rel, opts) -> bool`. The design said `path`; the root is separate so a
  hostile `rel` can be refused against it. `rel` is a decoded path (`gweb::path_decode`, or a `[name]` value).
- **Path rules.** In Goose: no empty, leading or trailing `/`, no empty segment, no segment starting with `.`, no `\`, no
  control byte, at most 1,024 bytes. In C: both `root` and the file go through `realpath`, and the file must be below the
  root (`/` boundary checked, so `/data/media2` is not inside `/data/media`). A symlink out of the root is a 404, a
  symlink inside is followed. Only regular files (`S_ISREG`) are sent. The open uses `O_NONBLOCK` so a FIFO cannot hang a
  worker.
- **Not found and refused look the same** (a plain 404), so a probe learns nothing. The function returns false so the
  caller can replace the reply.
- **ETag** is `"<size>-<mtime ns>"`: a 304 reads no file. It is strong, because the bytes behind one tag do not change
  unless size or mtime does. A replaced file in the CMS gets a new key anyway.
- **`Cache-Control`** is the caller's choice: `immutable` for keyed URLs, else `max-age=0, must-revalidate`.
- **Streaming.** Above `stream_over` (1 MiB) the file is sent in 256 KiB `pread` windows through `stream_begin`. Smaller
  files are read into `res.body`, so they carry a `Content-Length` and work under `gweb test` (which has no connection;
  there every file is read whole).
- **HTML and SVG** get `Content-Security-Policy: sandbox`. An uploaded page or SVG served from the app's origin could
  otherwise run script with the admin's cookies in reach. `nosniff` is already a default header.
- **Not done:** ranges, `If-Modified-Since`, compression. A HEAD for a streamed file has a chunked head with no
  `Content-Length`, because `begin_chunked` always writes `Transfer-Encoding`.

## Gaps the fixture exposed

Each has a regression test. Where the suspects named for this work were fine, that is recorded too.

| # | Gap | Fix | Test |
|---|---|---|---|
| 1 | `gweb.packages` took only `owner/repo@tag` from GitHub. A package from a local repo, a mirror or a bare repo made in a test could not be declared. The task's `file://...@tag` was a line that gweb rejected with "not a folder". | `file:///abs/path@tag` and `https://host/path@tag` are git sources. The address is checked (`. _ - + ~ / :`, no `..`), the tag as before. The clone goes to `<cache>/url/<source with / as %2F>`, and a cached tag is never fetched again. | `test/packages.sh` section 5 (11 checks: clone, routes, gen, no second fetch, five refusals); `test/cmsready.sh` installs the package this way |
| 2 | `validate` names fields plainly (`"title"`), but a form drawn with a prefix looks for the error under `prefix + field`. The message was stored and never shown. A CMS draws a page type's form and a widget's form in one page, so it always uses prefixes. | The generated `parse` runs `validate` into its own `FieldErrors` and adds each error under the prefix. | `test/views/site/tests/views.goose` (`test_parse`), `test/cmsready.sh` (422 shows the message at `t.title`) |
| 3 | A failed `g_parse` wrote no JSON, so the page could not draw the form again with what the editor typed. | `parse` writes the JSON it read in every case and returns false on errors. | the same two |
| 4 | `gweb test` could not set the `Host` header (a second `Host` line from `t.headers` is ignored, the first is `test`). An app with a channel per host could not be route-tested. | `Tester.host`. | `test/testing_test.goose`, `test/cmsready/site/tests/flow.goose` |

Checked and found working, with no change:

- **Views and components from a git-sourced package** merge with the app's: one registry holds the package's page type,
  section and widgets and the app's widget. Two layout views, one from each side, are both in `layouts`.
- **A nested mount under a git-sourced outer package.** `/admin/shop` gets the outer layout, the outer middleware and its own,
  nested in that order (root layout, package layout, module layout). The outer guard covers the module's pages.
- **`@slot` in a package's `layout.html`** and in package layout views. A component (`@Pill`) inside a view template, and
  a view field whose type comes from the package's lib (`cms::Media`), both build and run.
- **Cookies and CSRF under a mount.** The session and CSRF cookies are `Path=/` and `HttpOnly`, and `__Host-` with `Secure`
  behind `X-Forwarded-Proto: https`. A multipart upload with the token in a field passes the CSRF check.
- **`@asset` and `public/` of a mounted package.** The URL is hashed under the mount (`/admin/admin.<hash>.css`).
- **`gweb::reserved_prefixes()`** lists a mount (`admin`), a route folder (`media`), `sitemap.xml`, `robots.txt` and `_gw`.
- **Four workers.** After `epoch_bump()` no worker served an older page, and every reader saw the committed write.
- `gweb dev`, `gweb check` and `gweb build` (no warnings) on the project.

## Decisions in the fixture

- **The cache lives in a middleware beside the catch-all.** `cache_serve_key` has to run before the page loads, and
  `cache_store_key` after it renders. A page's `load` cannot do the second. `before` and `after` of
  `app/[[...path]]/middleware.goose` can, and a cache hit skips the database and the render.
- **The package sends owner messages through the host's `state.goose`**, as D9 says: one variant, `Cms { m: cms::Msg.. }`.
  The inner type is written `cms::Msg..` (a variable enum inside another needs the dots), and each `u8[>..]` in a message
  is passed as `copy(x)`.
- **The admin guard hard-codes `/admin/login`.** The package knows its own mount.
- **One user, `admin`.** The hash is the PBKDF2 string `test/auth` already uses, at 1000 iterations.

## Before a 1.0 freeze

- **`send_file`** has no ranges. Video and audio in Safari need them. Add `Range` for one range, and give a HEAD for a
  streamed file a `Content-Length` (needs a `begin_chunked` that can skip `Transfer-Encoding`).
- **A package does not know its mount.** The guard writes `/admin/login`. `gweb::mount(ctx)`, or a constant gweb writes
  into a package's namespace, would let one package mount anywhere.
- **A package's pages call `state::ask(ctx, state::Msg.Cms { ... })`**, which fixes the variant's name in the package.
  A typed hook the app registers (`fn route(msg) -> ...`) would remove the coupling.
- **A cache key hook for pages.** `const CACHE_KEY = site::key;` in `page.goose` would give a catch-all page the keyed
  cache without a middleware, and `REVALIDATE` could then mean "until the epoch" with no TTL.
- **`gweb.package` says `gweb 0.6`** (major.minor). A package that uses `send_file` cannot say it needs 0.7 until 0.7
  ships. The fixture package uses nothing newer than 0.6 itself.
- `FieldErrors` holds 16 errors. A page type with a long repeater and a widget form can reach it. The limit is silent
  (`dropped` is set).

## Resolved for 1.0

- **`send_file` HEAD.** A HEAD for a streamed file sends the head itself (`send_head`, with `Content-Type` and
  `Content-Length`), so it is no longer chunked. `Last-Modified` and `If-Modified-Since` are in (an IMF-fixdate; a
  request with `If-None-Match` ignores `If-Modified-Since`). Ranges are still not done: they need a `206` path in both the
  in-memory and the streamed branch, and are left for a 1.x minor.
- **A package knows its mount.** gweb writes `NAME::MOUNT` into a mounted package's namespace (`cms::MOUNT == "/admin"`,
  `shop::MOUNT == "/admin/shop"`). A constant, not `gweb::mount(ctx)`: the matched route's package is the module's,
  while the guard of the outer package needs its own. The fixture's guard and logout use it.
- **`gweb.package` versions.** `gweb 1.0` accepts any 1.x; `MAJOR.MINOR.PATCH[-PRE]` is compared as a version.
- **`FieldErrors`** holds 64. Past 63 the last slot becomes a form-level error and `dropped` is set.
- Not done: the typed owner hook that would replace `state::ask(ctx, state::Msg.Cms { ... })`, and `const CACHE_KEY`.
  Both are additions, so they can come in a 1.x minor.
