# Install

You need the [Goose compiler](https://aardappel.github.io/goose/), `git`, and
`node` if you run `gweb test`.

```
git clone --branch v0.5.0 --depth 1 https://github.com/josephheinz/gweb
cd gweb && goose build -o gweb cli/gweb.goose
ln -s "$PWD/gweb" ~/bin/gweb           # or: cp gweb ~/bin/
```

Make a project and run it:

```
gweb new mysite && cd mysite
GOOSE=/path/to/goose gweb dev
```

Open <http://localhost:60053>. `gweb dev` rebuilds and restarts on every
change.

## Rules

- `gweb` finds the compiler in `$GOOSE`, else `goose` on `PATH`.
- A linked `gweb` uses its checkout as the `web` package. A copied `gweb`
  declares the tagged releases from GitHub, and the compiler fetches them on
  the first build.
- `gweb version` prints the version and the sources it declares.
- `GWEB_SRC`, `GWEB_NET` and `GWEB_SQLITE` override a source with a path or a
  git source with `@ref`.

Next: the [tutorial](tutorial.md). Full reference:
[README](../../README.md#install).
