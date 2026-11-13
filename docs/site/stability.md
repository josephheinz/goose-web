# Stability and versions

## Versions

gweb, goose-net and goose-sqlite release together with one version.
`gweb` pins that tag of the other two. This holds through 1.x.

Each release names the Goose compiler version it was tested with.

## Before 1.0

- A minor release (`0.x.0`) may break. A patch (`0.x.y`) never does.
- Every break is a CHANGELOG line that starts with `Breaking:` and says how
  to migrate.

## From 1.0

- Breaking changes come only in a major release.
- A feature is deprecated in a minor release, with a `gweb` warning. It is
  removed no sooner than the next major.

## What is stable

- The project layout and file names.
- Template syntax.
- `.gshtml` syntax and the client subset. The subset may grow, not shrink.
- The signatures of `load`, `POST`, the route methods, `before`, `after`,
  `handle` and `init`.
- Documented `gweb::` functions and types.
- `gweb` commands, flags and environment variables.
- The shape of `gweb` messages: `path:line: error: msg`. The wording is not
  stable.
- `gw-target`, `gw-key`, the `GW-Fragment` header, the `gw_csrf` cookie, the
  `_csrf` field and the `/_gw/` URLs.

## What is not stable

- Everything in `.gweb*/`: generated code and `map.txt`.
- Message wording.
- The internals and size of `gwi.js`.
- Performance numbers.

## Security fixes

- They go to the latest minor release.
- After 1.0 they also go to the last minor of the previous major, for six
  months.

## The 1.0 bar

- The planned design work is built.
- These docs and the tutorial are current.
- One minor release has shipped with no `Breaking:` line.

The bar is a default. The maintainer may change it.
