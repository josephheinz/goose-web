# The `gweb` command

```
gweb [-C dir] new <dir>      a starter project
gweb gen                     write .gooseweb/ only
gweb build [--debug]         gen, then goose build to .gooseweb/server
gweb start [flags]           build and run
gweb dev [flags]             build, run, rebuild on change
gweb routes                  the route table
gweb test                    component parity tests
gweb version                 the version and the package sources
```

`-C dir` runs the command in `dir`.

| Command | Does |
|---|---|
| `new` | writes a starter project. The folder must be empty or missing. |
| `gen` | writes `.gooseweb/` and stops. |
| `build` | builds `.gooseweb/server`. `--debug` is passed to `goose build`. |
| `start` | builds and runs. Flags: `--port N --workers N --log --idle-ms N --max-body N`. |
| `dev` | like `start`, with `--log`, 2 workers and port 60053 unless `--port` is given. Rebuilds on change under `app/`, `lib/`, `public/` and `components/`. |
| `routes` | prints the route table, with a `frag` line for each fragment. |
| `test` | runs each component's `test_*` functions as Goose and as JavaScript. Needs `node`. Writes `.gooseweb.test/`. |
| `version` | prints the gweb version and the three sources it declares. |

## Rules

- `gweb` finds the compiler in `$GOOSE`, else `goose` on `PATH`.
- It finds the `web` package beside its own binary, or in `$GOOSE_WEB_HOME`.
  A checkout older or newer than the binary stops with "rebuild gweb".
- `GWEB_WEB`, `GWEB_NET` and `GWEB_SQLITE` override a package source.
- Generated files go in `.gooseweb/`, `.gooseweb.dev/` and `.gooseweb.test/`.
  Keep them out of git. They are not part of any stable interface.
- `WEB_WORKERS` sets the worker count. The default is the lesser of the
  performance cores and 4.

Full reference: [README](../../README.md#commands).
