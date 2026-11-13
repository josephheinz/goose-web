# Packages

A package adds components, routes, public files and Goose code to a project.

## Use one

List packages in `gweb.packages` at the project root, one per line.
`#` starts a comment.

```
../goose-admin at /admin
josephheinz/goose-widgets@v0.2.0
file:///srv/repos/cms.git@v1.0.0 at /admin
```

A source is a path (relative to the project, or absolute), `owner/repo@tag`,
or a git URL: `file:///abs/path/repo.git@tag` or `https://host/path@tag`.
`owner/repo@tag` is cloned from GitHub into
`~/.cache/gweb/pkgs/owner/repo@tag` (or `$GWEB_PKG_CACHE`) the first time; a
URL source goes under `url/` there, with its slashes written `%2F`. A cached
tag is never updated. Delete the folder to fetch it again.
The address may hold letters, digits and `. _ - + ~ / :`, and no `..` segment.

- **`at /prefix`** mounts the package's `app/` at `app/prefix/`, and its
  `public/` at `/prefix/`. The prefix is literal folder names: no `[id]`, no
  catch-all, not `/`. The project must not have `app/prefix/`, and two mounts
  must not use the same prefix. Layouts and middleware above the mount wrap the
  package's pages.
- **Nested mounts.** A package may be mounted inside another's mount:
  `./admin/shop at /admin/shop` beside `../cms at /admin`. The outer package
  must not have the folder `app/shop`. The inner pages get the outer layouts and
  middleware. Line order does not matter. A package folder must not sit inside
  the project's `app/`, `components/`, `lib/` or `public/`.
- **Components** join one flat namespace: call `@Badge(...)` as if it were in your
  `components/`. Two sources with the same name are an error naming both files.
- **Goose code** in the package's `lib/` is imported as `import NAME.file;`,
  and called as `NAME::fn()`.
- `gweb dev` also watches path packages. `gweb routes` lists package routes.

## Write one

A package is laid out like a project, with a `gweb.package` file at its root:

```
gweb.package
components/
app/            only with `at`
public/         only with `at`
lib/
```

```
name admin
gweb 0.3
```

`name` is a Goose identifier. `gweb` is the lowest gweb version it needs.

Files in `lib/` start with `namespace NAME;`:

```goose
namespace admin;

fn user_count() -> i64 { return 3; }
```

The project then writes `import admin.users;` and `admin::user_count()`.

## Refused

- `state.goose` and `not-found.html` in a package: the project owns the state
  and the 404 page.
- `app/` or `public/` in a package that has no `at`.
- A package name that is `lib`, `std`, `os`, `gweb`, `web`, `net`, `sqlite`, `main` or
  `state`, or that two packages share.
- A package that needs a newer gweb than yours:
  `admin: needs gweb 0.3 or newer (this is 0.2.1)`.
- A public file with the same URL as another, or as a route.

Errors name the package path.
