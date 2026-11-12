<!-- Produced by goose-architect on claude-opus-5-5 (medium) -->
# goose-web decision: `gweb test` writes its own output folder (v0.2.1)

## The bug

`test_cmd()` calls `gen(false)`, and `gen()` runs `c_remove_tree(".gooseweb")` before it regenerates. So `gweb test` deletes `.gooseweb/server` and rewrites the generated sources with test settings, and the user must run `gweb build` again. A `gweb dev` running beside it also loses its tree.

## Decision

`gen()` takes the output folder as a parameter. `build` and `gweb gen` pass `.gooseweb`, and `test_cmd` passes `.gooseweb.test`, a sibling folder. `gweb test` then never reads, writes or deletes anything in `.gooseweb/`.

- **Folder name.** `.gooseweb.test/`. It follows the `.gooseweb.dev/` sibling pattern, and one `.gitignore` glob idea (`.gooseweb*/`) covers all three, although the entries stay explicit.
- **Layout.** `.gooseweb.test/` holds the same tree as `.gooseweb/`: `main.goose`, `map.txt`, `Name.goose`, `_gw/` and the `lib` symlink. The parity program moves from `.gooseweb/test/` to `.gooseweb.test/parity/`: `main.goose`, `components_test`, `goose.out`, `run.mjs`, `js-pretty/`, `js-compact/`, and a `Name.goose -> ../Name.goose` symlink for each component. `gen()` wipes only the folder it was given.
- **How the folder reaches the helpers.** `gen(dev, root)` stores `root` in a module variable `gen_root`, next to `map_text`, `uses_sqlite` and the other per-gen state that `gen()` already resets. The helpers that write or read generated paths use it: `copy_prefixed`, `gen_template`, `gen_runtime`, `gen_components`, `rewrite_errors` and `component_lines_back`. Do not thread a parameter through the nine `copy_prefixed` and `gen_template` call sites; the file already shares per-gen state through module variables. Two module constants name the folders: `BUILD_DIR = ".gooseweb"` and `TEST_DIR = ".gooseweb.test"`.
- **Why the sibling works without other changes.** The generated `main.goose` embeds statics as `embed_file("../" + s.file)`, and `gen()` links `lib` as `../lib`. Both are relative to the output folder, and a sibling has the same depth as `.gooseweb/`, so both stay correct. The test binary never runs the generated `main.goose`, so the `_gw` static paths that point into `.gooseweb.test/` do no harm.
- **How `gweb dev` does it.** `.gooseweb.dev/` holds only `errors.txt`, through `write_dev_errors()`. `gweb dev` itself builds into `.gooseweb/`. No output-root mechanism exists to reuse, only the sibling-folder convention, and this decision reuses that convention.
- **`.gitignore`.** Add `.gooseweb.test/` after `.gooseweb.dev/` in `gweb new`'s template (`cli/gweb.goose`, the `[".gitignore", ...]` entry), in `goose-web/.gitignore`, in the lab `.gitignore` (`/Users/joeheinz/Documents/goose/.gitignore`, which covers `examples/shop`), and in `goose-net/.gitignore` and `goose-sqlite/.gitignore`.
- **README.** In the command table, the `gweb test` line becomes: `gweb test   component parity: test_* functions as Goose and as JavaScript (writes .gooseweb.test/; leaves .gooseweb/ alone)`. In the **`gweb test`** paragraph, add one sentence after "Needs `node`.": "It generates into `.gooseweb.test/`, so a built `.gooseweb/server` and a running `gweb dev` are untouched." Add a CHANGELOG `## v0.2.1` entry: "Fix: `gweb test` no longer deletes `.gooseweb/`; it generates into `.gooseweb.test/`. Add `.gooseweb.test/` to `.gitignore`."

### Rejected

1. Nested `.gooseweb/test/gen/`: `gen()` needs a keep-list exception, and the `../lib` symlink and the `embed_file("../...")` paths break at the extra depth.
2. Wipe everything except `server`: the server can be stale against its sources while still present, and the generated sources it was built from still change under it.
3. Move `server` aside and restore it: a crash or Ctrl-C loses it, the generated sources still change, and a running `gweb dev` still breaks.

## Risks

- **A missed `.gooseweb` literal.** A path the builder misses still writes into `.gooseweb/` during `gweb test`. The checksum check catches writes that change `server`, but not every write. The builder greps for `.gooseweb` after the change: every remaining hit must be the `BUILD_DIR` constant, the `.gooseweb.dev` lines, the `gweb new` `.gitignore` text, the usage text, the `gweb: wrote` and `gweb: built` messages, or `server_cmd`.
- **Error remapping.** In `test_cmd`, `format_replaced(out, ".gooseweb/test/", ".gooseweb/")` becomes one replacement per component: `TEST_DIR/parity/Name.goose` becomes `TEST_DIR/Name.goose`. `rewrite_errors` then maps that name back to `components/Name.gshtml`. Do not replace the whole `parity/` prefix, because that also rewrites the binary's path. If the remap is wrong, parity build errors show generated paths. Fail-case check 3 in `components.sh` uses `build`, not `test`, so it does not cover this. The builder runs the manual check in step 1.
- **Disk.** `.gooseweb.test/` stays after a run, like `.gooseweb/`. That is acceptable, and it is useful for inspecting `goose.out`.
- **Concurrent `gweb test` runs** in one site still race each other. The old code had the same race; it is out of scope.

## The second report (missing `.gooseweb/components_test`)

The design does not need to address it. The new regression check starts from a site with no `.gooseweb/` and covers it. The text probably came from the old remap: `".gooseweb/test/" -> ".gooseweb/"` also rewrote the binary path in goose's messages, which shows `.gooseweb/components_test` for a file that was really at `.gooseweb/test/components_test`. The per-component remap leaves that path as it is.

## Builder plan (one Sonnet 5.5 medium builder, one goose-web commit)

The work is in `/Users/joeheinz/Documents/goose/goose-web`. It is one commit, "Fix gweb test deleting .gooseweb/: generate into .gooseweb.test/".

### Step 1: code, docs and test, in one commit

1. In `cli/gweb.goose`:
   - Add `let BUILD_DIR = ".gooseweb";`, `let TEST_DIR = ".gooseweb.test";` and `var gen_root: u8[>..];`.
   - Change the signature to `gen(dev: bool, root: const u8[:])`. It sets `gen_root`, then runs `c_remove_tree(root)` and `make_dir(root)`, and links `lib` into `root`.
   - Replace each `.gooseweb/...` literal in `copy_prefixed`, `gen_template`, `gen_runtime`, `gen_components`, `gen()` (`main.goose`, `map.txt`), `rewrite_errors` and `component_lines_back` with `gen_root`.
   - `build` passes `BUILD_DIR` and builds `cwd/BUILD_DIR/server` from `cwd/BUILD_DIR/main.goose`. `gweb gen` passes `BUILD_DIR`.
   - `test_cmd` passes `TEST_DIR`. Every `.gooseweb/test/...` path becomes `TEST_DIR/parity/...`, including the `node` command line and the error remap described under Risks.
   - Add `.gooseweb.test/\n` to the `gweb new` `.gitignore` string.
   - Add one why-comment, above `TEST_DIR`: `// gweb test must never touch BUILD_DIR: a built server or a running gweb dev depends on it.` Write no other comments.
2. Add `.gooseweb.test/` to `goose-web/.gitignore`.
3. Update the README and the CHANGELOG as given under Decision. Set `VERSION` to `0.2.1` only if the user approves; see the user decisions below.
4. In `test/components.sh`, add a step 4, "gweb test leaves .gooseweb/ alone", that uses a new project `$WORK/keep`, a copy of `$WORK/ok`'s `app/` and `components/` with no `.gooseweb/`. It runs these checks in order. Each check is `ok` or `bad "<reason>"`:
   - `gweb -C "$WORK/keep" test` succeeds, `.gooseweb/` does not exist after it, and `.gooseweb.test/parity/components_test` exists.
   - `gweb -C "$WORK/keep" build` succeeds. Record `cksum` of `.gooseweb/server` and of `.gooseweb/main.goose`.
   - `gweb -C "$WORK/keep" test` succeeds again.
   - Both checksums are unchanged, and `.gooseweb/server` is still executable.
   Update the header comment's numbered list with item 4.

**Checks after the step:**

- `goose build -o gweb cli/gweb.goose` builds cleanly.
- `grep -n '\.gooseweb' cli/gweb.goose`: every hit is one of the allowed kinds listed under Risks.
- `GOOSE=... test/components.sh`: every check passes, the new ones included.
- `test/morph.sh` reports 21 passed.
- `test/release_check.sh` passes in full, including the `gweb_new` step and the fragments and catchall server steps.
- Manual remap check: put a type error in a `test_*` function of a copy of one parity component, then run `gweb test`. The error must name `components/Name.gshtml:LINE`, not `.gooseweb.test/...`. Undo the change.
- Shop check, in `/Users/joeheinz/Documents/goose/examples/shop`:
  1. `../../goose-web/gweb build`
  2. `cksum .gooseweb/server`
  3. `../../goose-web/gweb test` (it must pass)
  4. `cksum .gooseweb/server` (the same value as in item 2)
  5. `./.gooseweb/server --port 3995 &`, then `curl -fsS http://localhost:3995/` returns 200, and `curl -fsS http://localhost:3995/_gw/gwi.js` returns 200. Stop the server.
  Run the server directly, not through `gweb start`, because `gweb start` rebuilds and would hide the bug.
- `git status` in the lab root shows no untracked `examples/shop/.gooseweb.test/` once the lab `.gitignore` line is in place (that line is a separate commit, as below).

## Decisions for the user

1. **The sibling repositories.** Should the `.gooseweb.test/` line go into the lab root, `goose-net` and `goose-sqlite` `.gitignore` files? They are three separate git repositories, so each needs its own one-line commit outside the goose-web commit. Recommended: yes, all three. The lab one is needed for `examples/shop`.
2. **The release.** Should this ship as v0.2.1, with `VERSION` set to `0.2.1`, the CHANGELOG heading and a tag? Or should it wait under an unreleased heading?
