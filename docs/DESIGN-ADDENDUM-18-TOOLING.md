<!-- Produced by goose-architect on claude-opus-5-5 (medium) -->
# goose-web design: tooling and maturity (Addendum 18)

Scope, from `BACKLOG.md` "Tooling and maturity": the `.gshtml` language server, a documentation site and a tutorial, a stability and semver policy for v1.0, and a way for packages to ship components and routes.

## What I read, and the evidence

- `docs/BACKLOG.md`, `ARCHITECTURE.md`, `DESIGN.md`, `GSHTML-STUDY.md`, Addenda 1 to 11, `README.md`, `CHANGELOG.md`, `web.build`, `cli/*` (v0.2.1, rebased onto main).
- **Lines already line up.** `compile_template` turns every HTML line into one Goose line (`cli/gweb.goose`, "Every HTML line becomes one Goose line"). `copy_prefixed` puts `namespace ns; ` in front of line 1 and keeps every line. `component.goose` keeps the script and markup on their source lines and tags each line of the generated tail with `// gw:line N`. `rewrite_errors` and `component_lines_back` already map `goose build` errors back to source lines. So line mapping needs no new compiler work. Only columns are missing.
- **Goose's message format has no column.** The expected strings in `test/components/Fail*.gshtml` are `components/X.gshtml:5: error: ...`, after gweb's rewrite. The backlog uses the same `file:line: warning: message` form for gweb warnings.
- **Output folders.** Addendum 11 made `gen(dev, root)` write into a folder given by the caller (`gen_root`, `BUILD_DIR`, `TEST_DIR`). A third sibling for the editor costs one constant.
- **`goose lsp`** is named in the backlog. No `goose` binary is on this machine, so its capabilities (position encoding, files not on disk, symlinked imports) are unverified. `goose check` is used in Addenda 1 and 5, so it exists.
- **node 26** is on this machine and is already required by `gweb test`. No npm package may be installed here without the user's say-so.
- No sibling addendum existed when I wrote this. Addendum 12 (reactivity) owns the gweb warning channel, `--diagnostics json`, `--strict`, and heavy changes to `cli/component.goose`.

## Decisions

### D1. Source maps: line identity plus a column file

Lines stay identical, as today. gweb adds one file per output folder, `<root>/srcmap.txt`, with column segments for template and copied files:

```
gwmap 1
file about_html.goose app/about/page.html
L 1 1 0:0:0 182:5:7
L 4 4 0:0:0 31:9:12
file about.goose app/about/page.goose
L 1 1 0:0:0 15:0:0
```

- `file GEN SRC` starts a file. `GEN` is relative to the output folder; `SRC` is the path `map.txt` gives.
- `L G S seg...` maps generated line `G` (1-based) to source line `S`. Each segment is `gcol:scol:len`, 0-based byte columns, in rising `gcol` order. A segment covers generated columns from `gcol` up to the next segment's `gcol`. Inside `[gcol, gcol+len)` the column maps exactly (`scol + (c - gcol)`); past that it maps to `scol + len`. A column before the first segment maps to 0.
- A line with no `L` record maps to the same line number, column 0. A generated line that contains `// gw:line N` maps to line `N`, column 0. A line past the source's end maps to the source's last line.
- Segments are written for verbatim user text: each `{expr}`, `{#raw e}`, `{#if e}`, `{#else if e}`, `{#for ...}`, `{#let ...}` body, the name and arguments of an `@f(args)` or `@Name(expr)` call, the text of each line of a copied `.goose` file (one segment of the whole line, with line 1 shifted by the `namespace` prefix). Each `out.append("...")` of markup text gets a zero-length segment at its markup column, so an error inside generated scaffolding points at the right tag.
- **Components** keep line-level mapping only for now (identity plus `// gw:line`). Their column segments wait until Addendum 12 has merged (D7).

Why: the line identity is already the contract and is tested; a column file adds precision without touching it. A plain text format is trivial to write from Goose and to read from JS. `gwmap 1` lets the format change without breaking a reader silently. The file is internal (D5).

### D2. The language server is a Node program, launched by `gweb lsp`

- `editor/lsp/server.mjs`: one file, plain Node, no npm dependencies. It speaks LSP over stdio (`Content-Length` framing) to the editor, and it runs `goose lsp` as a child, speaking LSP to it too.
- `gweb lsp` embeds `server.mjs` (`embed_file`), writes it to `$XDG_CACHE_HOME/gweb/lsp-<version>.mjs` (default `~/.cache/gweb/`) when that file is missing or differs, and execs `node <file> --gweb <own path>`. A copied `gweb` binary works, like the embedded runtime does. With no `node` it stops with `gweb lsp needs node`.

Why Node: the backlog wants HTML and CSS services for the markup later, and those exist as npm packages (`vscode-html-languageservice`, `vscode-css-languageservice`) that a Node server can load when the user installs them. JSON and process handling come free, and the server is testable on this machine without a Goose compiler. Node is already a gweb dependency.

### D3. How diagnostics flow (v1: diagnostics only)

Files the server takes: `components/*.gshtml`, `app/**/*.html`, `app/**/*.goose`. (`lib/` files are real Goose modules; the user's own `goose lsp` setup handles them.)

1. **Start.** On `initialize` the server records the root folder. It spawns `goose lsp` (`$GOOSE`, else `goose` on `PATH`), initializes it with the same root and `general.positionEncodings: ["utf-8", "utf-16"]`, and runs one `gweb lsp-gen`.
2. **On open, change or save** of a taken file, after 250 ms of quiet, the server writes the buffer to a temporary file and runs `gweb -C ROOT lsp-gen --overlay SRC TMP`. One run at a time; a change during a run queues one more.
3. **`gweb lsp-gen`** runs `gen` into `.gooseweb.lsp/` (a sibling, like `.gooseweb.test/`), reading `SRC` from `TMP`. It writes `srcmap.txt` and prints gweb's own errors (and later Addendum 12's warnings) to stderr in the usual `path:line: error: msg` form. With `--check` it also runs `goose check` on `.gooseweb.lsp/main.goose` and prints its errors, mapped to source lines by `rewrite_errors`.
4. **The proxy.** For each generated file whose source is open, the server sends `didOpen` (first time) or `didChange` (full text) to `goose lsp` with the URI `file://ROOT/.gooseweb.lsp/GEN` and the text read from disk. Each `publishDiagnostics` from `goose lsp` for a generated URI is mapped through `srcmap.txt` to the source URI. Diagnostics for generated files with no open source (`main.goose`) are dropped.
5. **Publish.** For each source, the server publishes gweb's stderr diagnostics (whole-line range, line 0 shown on line 1) together with the mapped `goose lsp` ones.
6. **Fallback.** If `goose lsp` cannot start, exits, or does not answer `initialize` in 10 s, the server runs `gweb lsp-gen --check` on open and save instead, and publishes what it prints. It logs the reason once with `window/logMessage`.

Position encoding: the server offers `utf-16` to the editor (and `utf-8` if the editor lists it). Byte columns from `srcmap.txt` are converted using the line's text in each file. If `goose lsp` chose `utf-16`, its columns are converted to bytes with the generated text first.

### D4. `gweb check`

`gweb check` generates into `.gooseweb.check/` and runs `goose check`, printing mapped errors; exit 1 on any error. It is `lsp-gen --check` for humans and CI, and it never touches `.gooseweb/`. Addendum 12's `--strict` and `--diagnostics json` apply to it when they land; this addendum adds neither.

### D5. Stability and semver policy

Written as `docs/site/stability.md`. The rules:

- goose-web, goose-net and goose-sqlite release together with the same version, and `gweb` pins that tag of the other two. This stays through 1.x.
- **Before 1.0:** a minor release (`0.x.0`) may break; a patch (`0.x.y`) never does. Every break is a CHANGELOG line starting with `Breaking:` and says how to migrate.
- **From 1.0:** breaking changes only in a major release. A feature is deprecated in a minor release with a gweb warning (the channel from Addendum 12), and it is removed no sooner than the next major.
- **Stable (the public surface):** the project layout and file names; template syntax; `.gshtml` syntax and the client subset (it may grow, not shrink); the signatures of `load`, `POST`, route methods, `before`, `after`, `handle`, `init`; documented `web::` functions and types; `gweb` commands, flags and environment variables; the `path:line: error: msg` message shape (not its wording); `gw-target`, `gw-key`, the `GW-Fragment` header, the `gw_csrf` cookie and `_csrf` field, and the `/_gw/` URLs.
- **Not stable:** everything in `.gooseweb*/` (generated code, `map.txt`, `srcmap.txt`), `gweb lsp-gen`, message wording, `gwi.js` internals and size, performance numbers.
- Each release names the Goose compiler version it was tested with.
- Security fixes go to the latest minor release. After 1.0, also to the last minor of the previous major for six months.
- **1.0 gate:** Addenda 12 to 18 built, the docs site and tutorial current, and one minor release with no `Breaking:` line.

### D6. Packages that ship components and routes

A **gweb package** is a folder laid out like a project: `components/`, `app/`, `lib/`, `public/`, plus a manifest `gweb.package` at its root:

```
name admin
gweb 0.3
```

`name` is a Goose identifier; `gweb` is the lowest gweb minor version it needs. A project lists packages in `gweb.packages` at its root, one per line, `#` comments allowed:

```
../goose-admin at /admin
josephheinz/goose-admin@v0.1.0 at /admin
josephheinz/goose-widgets@v0.2.0
```

- **Sources.** A path (relative to the project, or absolute), or `owner/repo@tag`. A git source is cloned once with `git clone --depth 1 --branch TAG https://github.com/OWNER/REPO` into `$GWEB_PKG_CACHE/OWNER/REPO@TAG` (default `~/.cache/gweb/pkgs/`), and reused after that. `gweb` never updates a cached tag.
- **Components** join the project's flat namespace. A name that two sources define is a build error naming both files.
- **Routes.** `at /prefix` grafts the package's `app/` at `app/prefix/`. The prefix is one or more literal folder names (no `[id]`, no catch-all, not `/`). The project must have no `app/prefix/` folder. Layouts and middleware above the mount point wrap the package's pages, as for any folder. A package without `at` must have no `app/`.
- **Public files** of a mounted package are served under the prefix (`public/x.css` at `/prefix/x.css`). A package without `at` must have no `public/`.
- **Goose code.** The package's `lib/` is linked at `<root>/NAME` in the output folder, so package code writes `import NAME.users;` (with `namespace NAME;` or below it, as lib modules do now). A package's own route and page files are compiled as app files, with gweb's namespaces.
- **Refused in a package:** `app/state.goose`, `app/not-found.html` (one owner and one 404 page per app). Errors name the package path.
- **Versions.** A package needing a newer gweb minor fails with `PACKAGE: needs gweb 0.3 or newer (this is 0.2.1)`.
- `gweb dev` also watches the folders of path packages. `gweb routes` shows package routes with their mount.

### D7. What waits

- Column maps for components, until Addendum 12 has merged (its compiler changes would collide). Line mapping for components works now.
- Hover, completion, go to definition, and HTML and CSS services: version 2 of the server. The proxy design above carries them (forward requests, map positions both ways).
- A VS Code extension. It needs `vscode-languageclient` from npm; editors with a generic LSP client (Neovim, Helix, Zed, VS Code with a generic client extension) use `gweb lsp` now. `docs/site/editor.md` shows the setup.
- A docs site served by gweb. It needs markdown rendering, which gweb lacks. The docs are Markdown under `docs/site/` and read on GitHub for now.

## Rejected alternatives

1. **Server in Goose, inside `gweb`.** One binary, but it needs a JSON parser and a process multiplexer written in Goose, cannot be tested here, and cannot reach the npm HTML and CSS services later.
2. **Standard JavaScript source maps (VLQ JSON).** Built for many-to-one generated code. Goose lines are already one-to-one, and VLQ would need an encoder in Goose for no gain.
3. **Diagnostics from `goose check` only, no `goose lsp`.** Works on save only, and gives no route to hover and completion. Kept as the fallback.
4. **A `--dry` gen that writes nothing.** The output-folder parameter from Addendum 11 already isolates editor output in `.gooseweb.lsp/`, and `goose lsp` needs the other generated files on disk anyway.
5. **A new repo for the docs, or a gweb-rendered site now.** The task puts the docs in goose-web, and gweb has no markdown rendering yet.
6. **Moving README sections into the docs site now.** Every sibling architect edits `README.md`; moving its sections now would conflict with all of them. The guide pages are short and link to the README for the full rules. The README is cut down to install plus links before 1.0 (Step 8).
7. **Package components under `@pkg::Name()`.** `@ns::f()` already means a function call. A flat namespace with a clash error is simpler.
8. **Packages declared as Goose imports and fetched by the compiler.** gweb must read `.gshtml` and `page.html` files itself, and the compiler's fetch cache is not a documented place.

## Risks

- **`goose lsp` is unverified.** It may not accept generated files sent by `didChange`, may reject symlinked `lib`, or may only speak UTF-16. The fallback (D3.6) keeps diagnostics working on save. The proxy is tested against a fake `goose lsp`.
- **Speed.** `lsp-gen` runs a whole `gen` per pause in typing. Fine for small apps; a per-file gen is a later optimisation.
- **Merge conflicts.** Steps 1, 3 and 6 edit `cli/gweb.goose`, which most sibling architects also edit. Keep edits local to the functions named.
- **Docs drift** between README and `docs/site/`. Step 8 removes the duplication before 1.0.

## Open questions for the user

1. **1.0 gate.** Default: Addenda 12 to 18 built, docs current, and one minor with no breaking change. Is that the bar?
2. **Security support window.** Default: latest minor; after 1.0 also the previous major's last minor for six months.
3. **Git package sources.** Default: gweb clones `owner/repo@tag` from GitHub itself. The alternative is path sources only (users clone or vendor).
4. **A VS Code extension** with an npm dependency. Default: not now; document generic-client setup.
5. **README.** Default: trim it to install plus links to `docs/site/` before 1.0, after the sibling addenda merge.

## Build plan

Each builder works in `/Users/josephheinz/Documents/goose/goose-web/.worktrees/tooling` (branch `arch/tooling`), edits only inside it, commits only its own files (`git commit -- paths`), never pushes. No `goose` compiler is on this machine: builders check `$GOOSE` and `PATH`, write code and tests anyway, run what runs without it, and say what is untested.

Order: Steps 1, 2, 4 and 5 run in parallel (disjoint files). Step 3 after 1 and 2. Step 6 after 3. Step 7 after 3 and 6. Step 8 after the sibling addenda merge.

### Step 1. Column positions in the template compiler (`cli/gweb.goose`)

- Add `var srcmap_text: u8[>..];`, reset in `gen()` beside `map_text`, written to `<root>/srcmap.txt` beside `map.txt`, starting with `gwmap 1\n`.
- `compile_template`: track the column in the generated line (bytes since the last `\n` in `out`). In `template_tag` and `template_call`, record a segment wherever user text is copied verbatim (D1 list): find where the expression starts in `line` (`at + 1` plus the trimmed offset) and where it lands in `out`. Record a zero-length segment before each markup `out.append("`. Emit one `L` record per line that has segments. `gen_template` writes `file GEN SRC` then the records, only for the attempt that is kept.
- `copy_prefixed`: `file NS.goose SRC`, then `L 1 1 0:0:0 P:0:N` where `P` is the prefix length and `N` the line's length, and `L i i 0:0:N` for the other lines (or rely on identity; line 1 is required).
- No change to `component.goose`.
- **Tests:** `test/srcmap.sh` plus `test/srcmap/` fixture project (a page with `{expr}`, `{#if}`, `{#for}`, `@f(x)`, a component call, a layout, a `page.goose`) and `test/srcmap/expected.txt`. The script runs `gweb -C fixture gen` and diffs `.gooseweb/srcmap.txt` against the expected file. Write `expected.txt` by hand from the rules.
- **Done:** `gweb gen` writes `srcmap.txt`; no generated `.goose` byte changes (diff a fixture's `.gooseweb/*.goose` before and after); the script passes when a compiler is available.

### Step 2. The language server (`editor/lsp/server.mjs`)

- One ES module, no dependencies. Exports `parseSrcmap(text)`, `mapPosition(map, genFile, genLine, genByteCol, genText, srcText)`, `byteToUtf16(lineText, byteCol)`, `utf16ToByte`, and `parseGwebDiagnostics(stderrText, root)`. Runs the server when executed directly (`import.meta.url` check).
- Implements D3 exactly: framing, `initialize`/`initialized`/`shutdown`/`exit`, `textDocument/didOpen|didChange|didSave|didClose` (full sync), debounced `lsp-gen` via `--gweb PATH` (or `$GWEB_BIN`), the child `goose lsp` with request ids, mapping, publishing, the fallback. Clears diagnostics on close.
- **Tests:** `test/lsp/srcmap_test.mjs` (format parse, exact and clamped columns, zero-length anchors, identity lines, `// gw:line`, past-end lines, UTF-8 to UTF-16 with multibyte text). `test/lsp/proxy_test.mjs` with `test/lsp/fake-gweb.mjs` (writes a fixed `.gooseweb.lsp/` tree and `srcmap.txt` into the root it is given, prints one gweb error on stderr) and `test/lsp/fake-goose.mjs` (answers `goose lsp` with one diagnostic per opened generated file at a known column). It drives `server.mjs` over stdio and checks mapped ranges for a `.gshtml` and a `page.html`, the merged gweb error, clearing on close, and the fallback when the fake is told to exit. `test/lsp.sh` runs both with `node`.
- **Done:** `test/lsp.sh` passes on this machine.

### Step 3. `gweb lsp-gen`, `gweb check`, `gweb lsp` (`cli/gweb.goose`)

- `let LSP_DIR = ".gooseweb.lsp"; let CHECK_DIR = ".gooseweb.check";`
- Overlay: `var overlay_src`, `overlay_tmp`; `read()` reads `overlay_tmp` when the path equals `overlay_src`.
- `lsp-gen [--check] [--overlay SRC TMP]`: `gen(true, LSP_DIR)`; with `--check`, `goose check --color never` on `LSP_DIR/main.goose`, output through `rewrite_errors` to stderr. Exit 0 even with errors (the server reads stderr). Not in `usage()`.
- `check`: `gen(false, CHECK_DIR)` then the same check; exit 1 on any error; prints `gweb: check passed` otherwise.
- `lsp`: `let LSP_JS = embed_file("../editor/lsp/server.mjs");`, write to the cache path if different, `c_exec` `node FILE --gweb SELF` (the path from `resource_dir`/`args()[0]`).
- Add `.gooseweb.lsp/` and `.gooseweb.check/` to the `gweb new` `.gitignore` and to `goose-web/.gitignore`. Add `check` and `lsp` to `usage()` and the README command table.
- **Tests:** extend `test/srcmap.sh`: `lsp-gen --overlay` with a temp file holding a changed page writes the changed text into `.gooseweb.lsp/` and leaves `.gooseweb/` absent; `check` on a fixture with a type error in `page.html` prints `app/page.html:LINE: error:` and exits 1.
- **Done:** the grep rule of Addendum 11 holds for the new constants; tests written; untested without a compiler.

### Step 4. Documentation site and tutorial (`docs/site/`)

- `docs/site/README.md` (index), `install.md`, `tutorial.md`, `routing.md`, `templates.md`, `components.md`, `fragments.md`, `forms-and-csrf.md`, `cookies.md`, `state-and-sqlite.md`, `cli.md`. Short pages: what it is, one example, the rules that matter, then a link to the README section for the full reference. Plain words, few of them.
- The tutorial builds a notes app in steps: `gweb new`, a page with `load`, a layout, a JSON route, owner state holding the notes, a form with CSRF and a fragment, a component (a character counter). The finished app is `docs/site/tutorial/notes/` (`app/`, `components/`), and every code block in `tutorial.md` matches a file in it.
- **Tests:** `test/tutorial.sh` builds `docs/site/tutorial/notes` with `gweb`, starts the server on a free port, checks `/` (200, contains the title), the JSON route, a CSRF POST (403 without the token, 303 or 200 with it), then stops it.
- **Done:** pages written; script written; untested without a compiler.

### Step 5. Stability policy (`docs/site/stability.md`)

- D5, written for users. No other files.
- **Done:** the page exists and matches D5.

### Step 6. Packages (`cli/gweb.goose`)

- `struct Pkg { name, dir, mount, git: bool }`, `var pkgs: Pkg[>..<]`, read in `scan()` from `gweb.packages`; each package's `gweb.package` checked (name, version).
- `Dir` gains `root: u8[..512]`, the folder its files live in (`app` or `PKGDIR/app`). `app_path` takes the `Dir` (or its root). `scan_dir` takes a root and a rel prefix, so a mounted package's folders get `rel = prefix/...`. `scan_public_dir` the same for public. `scan_components` also lists each package's `components/`, with the clash error. Component source paths are stored, not rebuilt from the name.
- `gen()`: link `<root>/NAME` to the package's absolute `lib/`; scan package `lib/` for `import sqlite;`. Refuse `state.goose` and `not-found.html` in packages. `dev` watches path packages' folders. `routes` prints package routes.
- Git sources: `git clone` as in D6, into the cache, when the folder is missing.
- **Tests:** `test/packages.sh` with `test/packages/app/` (a project, `gweb.packages` naming `../pkg at /admin`) and `test/packages/pkg/` (manifest, a page with a layout, a route, a component, a `lib/` module used by the page, a public file). Checks: `gweb routes` lists `/admin/...`; build succeeds; the server serves the package page inside the project's root layout, the route, the public file at `/admin/x.css`, and a project page using the package component. Error cases, each in its own copy: a clashing component name, `app/admin/` in the project, `state.goose` in the package, a too-new `gweb` line, a bad mount (`/[id]`).
- **Done:** tests written; untested without a compiler.

### Step 7. Docs for the new tools

- `docs/site/editor.md`: `gweb lsp`, what it reports, setup for Neovim, Helix, Zed and a generic VS Code client; the fallback. `docs/site/packages.md`: writing and using a package. `docs/site/cli.md` gains `check` and `lsp`. README: a link to `docs/site/` under the title, and a `Packages` section of a few lines.
- **Done:** pages written and linked from `docs/site/README.md`.

### Step 8. Later (not in this branch)

- Component column maps, after Addendum 12 merges.
- LSP version 2: hover, completion, definitions, HTML and CSS services.
- Trim `README.md` to install plus links, after the sibling addenda merge.
