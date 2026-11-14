# Building a CMS on gweb

A CMS is a gweb package that adds an admin to an app, and a few lines in the app that show what the admin stores.
gweb has no CMS code. It has the parts a CMS needs: packages with mounts, views, a page cache, sessions, uploads and
a file server.

The worked example is `test/cmsready/`. It is small on purpose, and `test/cmsready.sh` drives it over HTTP.

## Who owns what

```
cms/                         the package (a git repo)
  gweb.package               name cms, gweb 0.6
  app/                       the admin pages, mounted at /admin
    layout.html              the admin shell
    middleware.goose         the login guard
    login/, logout/, nodes/[id]/, media/, new/
  views/                     page types, sections, widgets and layouts
  components/                client components (Pill)
  public/admin.css           served at /admin/admin.css
  lib/                       store.goose (SQLite), msg.goose (owner messages), media.goose (a field type)

site/                        the host app
  gweb.packages              the package at /admin, a local module at /admin/shop
  admin/shop/                the module: its own gweb.package, pages, layout, component
  app/state.goose            the one writer; wraps the package's messages
  app/[[...path]]/           the public site: catch-all page, and middleware for the cache
  app/media/[key]/[name]/    files, through gweb::send_file
  app/sitemap.goose          sitemap and robots, per host
  app/layout.html            the root layout (wraps the admin too)
  views/                     the host's own views: a layout and a widget
  lib/site.goose             glue between stored documents and the generated registry
```

The package cannot own `state.goose`, `not-found.html` or `config.goose`. The app does. That is why the app has one
file of glue for the store.

## 1. Install the package

```
# gweb.packages
file:///srv/repos/cms.git@v0.1.0 at /admin        # or josephheinz/goose-cms@v0.1.0 at /admin
./admin/shop at /admin/shop                       # a module, inside the mount
package pg josephheinz/goose-postgres@v0.1.0      # a Goose library the CMS's files import as `import pg;`
```

The CMS's own `gweb.package` can carry the `package` lines it needs (`package blob josephheinz/goose-blob@v0.1.0`),
and gweb declares them in the root.

The package is cloned once into `~/.cache/gweb/pkgs` (or `$GWEB_PKG_CACHE`). Its `app/` becomes `app/admin/`, its
`public/` becomes `/admin/`, its components and views join the app's. A layout or middleware above the mount wraps
the package's pages. The module is mounted inside the package and gets the package's layout and guard too. See
[Packages](packages.md).

## 2. Guard the admin

`cms/app/middleware.goose` runs for every page under `/admin`, the module's pages included:

```goose
fn before(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) -> bool {
    var login: u8[>..] = [];
    format(login, cms::MOUNT, "/login");      // gweb writes cms::MOUNT: "/admin" here, wherever the host mounts it
    if starts_with(req.target, login) { return true; }
    return gweb::require_login(req, ctx, res, login);
}
```

A package does not hard-code its mount. gweb writes `NAME::MOUNT` (here `cms::MOUNT`) into the package's namespace.

An admin that loads pages with `gw-target` or `gw-boost` gets a `401` and a `gw:unauthorized` event when the session has
expired, not the login page morphed into the target. The runtime goes to the login unless a listener cancels the event.

`login/submit` checks the password with `gweb::password_verify` and calls `gweb::login`. The session and CSRF cookies are
`Path=/`, host-only, and `__Host-` behind HTTPS. Mounts do not change them. Because the cookie is host-only, put the
admin on one host.

## 3. Views: page types, sections, widgets

```
views/types/Article.goose    struct Props { title, theme, intro }, fn validate
views/types/Article.html     ... @slot("main", "TwoColumn Text Quote Image") ...
views/sections/TwoColumn.*   two slots: left and right
views/widgets/Text.*         body: u8[..600], editor "markdown"
views/widgets/Image.*        media: cms::Media, a field type of the package's lib
```

gweb generates, for the whole app, a `views` module with `types_render`, `widgets_render`, `types_form`,
`types_parse`, `types_defaults` and `types_meta` (and the same for each group). The package's views and the app's join one
registry. See [Views](../../README.md#views).

A field type of your own (`cms::Media`) is four functions beside the type: `gw_read`, `gw_write`, `gw_field` and
`gw_parse`.

## 4. Store and state

SQLite readers run on the workers, with `sqlite::local(path, Mode.QueryOnly)`. One writer runs on the owner thread.
The package defines the messages and the handler. The app wraps them in one variant:

```goose
// app/state.goose
const VARIABLE_MSG = true;                    // the messages carry text of any size
enum Msg { Cms { m: cms::Msg.. } }
struct Reply { cms: cms::Reply }
fn init() { cms::init(); }                    // writer, schema, seed
fn handle(msg: const Msg..&) -> Reply {
    match msg { Cms c => { return Reply { cms: cms::handle(c.m) }; } }
}
```

A page sends with `state::ask(ctx, state::Msg.Cms { m: cms::Msg.Save { id: id, props: copy(json), .. } })`. A variable
message needs `copy(...)` for each `u8[>..]` it holds.

## 5. Show it: a catch-all, by name

`app/[[...path]]/page.goose` loads the node for the request's host and path. `page.html` is one line:
`@site::page(req, ctx, props.doc)`. `lib/site.goose` renders the channel's layout view, and a `fill` function answers
every `@slot` by looking up stored widgets and calling `views::widgets_render(out, req, ctx, name, json, doc, at, fill)`.
The view name and its JSON come from the database.

```goose
recursive fn fill(out: u8[>..]&, req: const http::Request&, ctx: const gweb::Ctx&, doc: const cms::Doc&, at: i64, name: const u8[:]) { ... }
```

The Text widget calls `@gweb::markdown(props.body)`. Render at read time. The cache absorbs the cost.

## 6. Hosts and the cache

One app serves every host. The Host header picks the channel (`channel_by_host`). An unknown host is a 404, never a
default site.

The cache key is host plus path, so two hosts do not share an entry. A middleware beside the catch-all does both
halves:

```goose
// app/[[...path]]/middleware.goose
fn before(req, ctx, res) -> bool {
    if site::cache_key(req, key) && gweb::cache_serve_key(req, ctx, res, key) { return false; }
    return true;
}
fn after(req, ctx, res) { if site::cache_key(req, key) { gweb::cache_store_key(req, ctx, res, key, 0); } }
```

TTL 0 means "until `gweb::epoch_bump()`". The admin calls it after every write, from the worker. Every worker drops its
cache on its next lookup. A page with a CSRF token or a cookie is never stored.

`app/sitemap.goose` calls `gweb::sitemap_base(s, "https://" + host)` and lists that host's nodes. `fn robots` writes
the host's `robots.txt`. The admin pages set `const SITEMAP = false;`.

## 7. Slugs that cannot collide

The admin refuses a new path whose first segment is in `gweb::reserved_prefixes()`: every route folder (the mount
`admin`, `media`), every `public/` name, `sitemap.xml`, `robots.txt` and `_gw`. See `cms::slug_ok`.

## 8. Media

The upload page has `fn POST` with a `gweb::Upload` field and `const MAX_UPLOAD`. It asks the owner for a key, then
`gweb::save_upload(file, "data/media/m<id>/<name>")`. The app serves it:

```goose
// app/media/[key]/[name]/route.goose
var opts = gweb::FileOptions { .. };
opts.immutable = true;
gweb::send_file(req, ctx, res, "data/media", rel, opts);
```

`send_file` refuses `..`, dotfiles and symlinks out of the root, answers 304 on `If-None-Match`, supports HEAD and
streams big files. Set `opts.sandbox = true` for a PDF or any type a browser might script (HTML and SVG are sandboxed already).
`gweb::image_size(bytes)` (`import gweb.site.image;`) gives an upload's width and height. See [Serving files from disk](../../README.md#serving-files-from-disk).
To keep media on S3 or behind a CDN, use goose-blob: [Media storage](packages.md#media-storage).

## 9. Test it

`gweb test` runs `tests/*.goose` with the real dispatcher. Set `t.host` to test each host, log in through the package,
post the generated form and check the public page changes. `tests/cms.goose` checks the registry (package and app views
together), the slots, the foreign field and the reserved prefixes.

`test/cmsready.sh` does the same over HTTP with a real server: login with CSRF, an edit that fails `validate` (422,
the message shown at the field), an edit that passes, the cache epoch on four workers, an upload, `/media` with 200,
304, HEAD, a streamed file and hostile paths.

## Things to know

- `validate` names fields plainly. The generated parser adds the form prefix to each error, so it shows at the control.
- After an error `types_parse` still writes the JSON it read. Draw the form again from it, so the editor keeps what was
  typed.
- Pages that start a CSRF token are never cached. Keep forms off public pages.
- The owner runs every write. Reads on workers see a commit at their next statement.
- A guard's `before` returning false skips the `after` of middleware above it.
