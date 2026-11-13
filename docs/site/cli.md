# The `gweb` command

```
gweb [-C dir] new <dir>      a starter project
gweb gen                     write .gweb/ only
gweb build [--debug]         gen, then goose build to .gweb/server
gweb start [flags]           build and run
gweb dev [flags]             build, run, rebuild on change
gweb export [-o DIR]         build, then write the site as static files
gweb routes                  the route table
gweb test                    component parity tests, then tests/*.goose
gweb check                   goose check on a copy of the site
gweb lsp                     language server for editors
gweb version                 the version and the package sources
gweb help                    the usage
```

`-C dir` runs the command in `dir`.

`gweb help`, `gweb --help`, `gweb -h` and `gweb COMMAND --help` print the usage on stdout and exit 0.
`gweb --version` is `gweb version`. A wrong command line prints the reason and the usage on stderr and exits 2.

| Command | Does |
|---|---|
| `new` | writes a starter project, with a `.gitignore`, a `Dockerfile` and a `.dockerignore`. The folder must be empty or missing. |
| `gen` | writes `.gweb/` and stops. |
| `build` | builds `.gweb/server`. `--debug` is passed to `goose build`. |
| `start` | builds and runs `.gweb/server`. The flags after `start` go to the server (below). |
| `dev` | like `start`, with the dev defaults below. Rebuilds on change under `app/`, `lib/`, `public/`, `components/`, `locales/`, `stores/` and `views/`, and in path packages (the same folders but `locales/`). |
| `export` | builds, then renders the site in process and writes it to `-o DIR` (default `out/`): HTML files, static files, `sitemap.xml`, `robots.txt`. No port. Run it with `SITE_URL` set. |
| `routes` | prints the route table, with a `frag` line for each fragment. |
| `test` | runs each component's `test_*` functions as Goose and as JavaScript (needs `node`), then every `tests/*.goose` route test with the app's real dispatcher. Writes `.gweb.test/`. |
| `check` | generates into `.gweb.check/` and runs `goose check`. Errors name `.gshtml`, `.html` and app `.goose` lines. Exit 1 on any error. |
| `lsp` | runs the language server over stdio. Needs `node`. See [Editor support](editor.md). |
| `version` | prints the gweb version and the three sources it declares. |

`gen`, `build`, `start`, `test` and `check` take `--strict` (any warning fails the run) and `--diagnostics json`
(stderr becomes JSON Lines: `{"severity","file","line","code","message"}`). `gen`, `build`, `start` and `export` take
`--no-minify`.

Two commands are not in the usage because they are internal: `lsp-gen` (the editor server asks for the generated tree)
and `test-css` (the CSS minifier's own check). `semver-cmp` is a test helper. None of the three is stable.

## Server flags

`gweb start` passes its flags to `.gweb/server`, which also runs by itself (a container runs it). Every setting has a
flag and a `GWEB_*` variable of the same name. A flag beats the variable. A bad value stops the server with exit status 2
and a message that names the flag or variable. `server --help` prints them. The whole table is in
[Deploy](../DEPLOY.md#config-summary).

```
--port N --host H --workers N --access-log --idle-ms N --max-body N --max-upload N --upload-dir D
--max-upload-parts N --max-upload-files N --max-upload-text N --csp --trust-proxy --security-headers --hsts N
--session-idle N --session-max N --drain-ms N --drain-delay-ms N --log-format text|json --log-level L
--metrics --job-runners N --job-queue N --job-attempts N --no-schedule --probe
```

- Booleans are `1/0`, `true/false`, `yes/no`, `on/off`. A boolean flag is bare (`--metrics`), `--no-metrics`, or
  `--metrics=off`. `--no-schedule` is `GWEB_SCHEDULE=0`.
- `--port` is 1 to 65535. `--idle-ms` is 0 or more (0 never closes). `--max-body` is 1 or more.
- `PORT` is an alias of `GWEB_PORT`. `GWEB_PORT` wins.
- `--access-log` was `--log`. The old name is refused with a message that names the new one.
- `--probe`, `--export DIR` and `--dev-id N` are flags only: they choose a mode. `GWEB_SECRET` and `GWEB_ENV` are
  variables only.

## `gweb dev`

`gweb dev` passes `--dev-id` to the server, which then defaults to: host `127.0.0.1`, port 60053, 2 workers, the
access log, and `--drain-ms 200`. The flags and variables still win, `.env` files included:

- `gweb dev --host 0.0.0.0` (or `GWEB_HOST=0.0.0.0`) opens the dev server to the network. It carries the dev overlay,
  `/__gweb/id` and a dev secret, so do that on a network you trust.
- `start` and the server keep `0.0.0.0`, because a container needs it.

## Rules

- `gweb` finds the compiler in `$GOOSE`, else `goose` on `PATH`.
- It finds the gweb checkout beside its own binary, or in `$GWEB_HOME`.
  A checkout older or newer than the binary stops with "rebuild gweb".
- `GWEB_SRC`, `GWEB_NET` and `GWEB_SQLITE` override a package source.
- Generated files go in `.gweb/`, `.gweb.dev/`, `.gweb.test/`, `.gweb.check/` and `.gweb.lsp/`; uploads spool to
  `.gweb.uploads/`. Keep them out of git (`gweb new` does). They are not part of any stable interface.
- Packages are listed in `gweb.packages`. See [Packages](packages.md).
- `GWEB_WORKERS` sets the worker count. The default is the lesser of the performance cores and 4.

Full reference: [README](../../README.md#commands).
