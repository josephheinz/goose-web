# Addendum 19: goose-cms phase 1, the gweb side

Builds "Phase 1: gweb" of `docs/CMS-DESIGN.md` (branch `arch/cms`) and the prerequisites it assigns to gweb. The design was
written before the rename and before a compiler existed, so this record states what the compiler showed. Names are
`gweb::`, runtime modules are in folders, and `GWEB_*` are the env vars.

## Phase 0 experiments (gweb side)

All run with Goose v2026.4, in a scratch folder, nothing committed.

| | Question | Result |
|---|---|---|
| E1 | Does the struct parser handle `Props` with an enum, a nested struct, a repeater and a foreign type? | **Yes.** `cli/structs.goose` plus `cli/views.goose`. The form decoder generator now uses the same scanner. `cli/component.goose` keeps its own token-based parser (see Deviations). Covered by `test/views.sh`. |
| E2 | Does std `json` decoding cover the codec? | **Yes. No pull reader was written.** `json::reader`, `each_member`, `each_element`, `peek`, `skip`, `read_string` and `read_bool` are enough. One gap: the std errors are sticky (a wrong-type read ends the whole parse), so `site/views.goose` checks `peek` before each read and scans an int token itself (`jr_int`). A wrong type, a fraction in an int, a number over 18 digits and an unknown enum name become a warning and keep the default. |
| E3 | Does `views::g_render<fill>` pass `fill` across namespaces? | **Yes, with two corrections.** (1) `<fill>` is not the syntax: a function value is passed as the **last argument**, `views::types_render(out, req, ctx, name, json, doc, at, fill)`, and the callee declares `<Z, D>` with no parameter for `Z`. (2) The user's `fill` must be `recursive fn` (it is the entry of a cycle: `fill` -> `types_render` -> `render` -> `Z`). The generated functions need no `recursive`. |
| E4 | Can a `u8[]` of 256 KiB travel in a `state::ask` variant? | **Yes, in variable mode.** `enum Msg { Save { id: i64, doc: u8[] }, ... }` is refused in fixed mode ("can only be used in variable mode (Msg..)"). It works as `Msg..`, with `handle(m: const Msg..&)` and `owner_call_fd<Msg.., Reply>`. 200 round trips of 256 KiB took 0.26 ms each. This needed two changes: `owner_call_fd` pushes `copy(msg)`, and gweb must write `state::Msg..` in the generated `state::ask` and `owner_loop`. An app says so with `const VARIABLE_MSG = true;` in `app/state.goose`. A fixed `u8[..262144]` would make every message 256 KiB, so it was not measured. |
| E5 | Markdown speed on 20 KB. | **0.13 ms** per render of a 21.7 KB document (200 renders). The design's "2 to 10 µs per page" estimate is for stored pages; markdown is on top of it and cached with the page. |
| E9 | A package mounted inside another package's mount. | **Already built** (commit `fd5b820`, `check_nested_mounts`). `test/packages.sh` section 4 (`/admin/shop` inside `/admin`, any depth, either line order, a clash with the outer package's folder is an error) passes 32 of 32. Nothing to add but the README paragraph. |

E6 to E8 belong to goose-cms.

## What was built

| Item | Where |
|---|---|
| Views, registries, `ViewMeta`, `FieldUi`, `Renamed`, `form_enum`, `@slot("x")` | `cli/views.goose`, `cli/structs.goose`, `site/views.goose`, edits in `cli/gweb.goose` (`K_VIEW`, `view_slot`, scan, gen) |
| `gweb::markdown`, `markdown_text` | `site/markdown.goose` |
| `export { morph }` | `client/gwi.js` (`gwi.min.js` 4,079 bytes) |
| `gweb::reserved_prefixes()` | `gen_reserved` in `cli/gweb.goose` |
| `cache_serve_key`, `cache_store_key`, `epoch_bump` | `http/cache.goose`, `src/cache.c`, `src/cache_core.[ch]` |
| `sitemap_base`, optional `fn robots` | `site/sitemap.goose`, `cli/gweb.goose` |
| Package `views/` merging | `vw::scan` |
| Nested mounts (D11) | already present; tested |
| Variable-size state `Msg` | `ops/owner.goose`, `msg_ty` in `cli/gweb.goose` |

Tests: `test/markdown_test.goose` (135 checks), `test/views.sh` (26 checks, with `gweb test` on `test/views/site`: 8 tests, 102
checks), `test/cache.sh` and `test/cache_test.c` (epoch), `test/sitemap.sh` (multi-host base, `fn robots`),
`test/morph_export_test.mjs`.

## Design changes and deviations

- **Call syntax.** `views::g_render<fill>(...)` is `views::g_render(..., fill)` (E3). The glue's `fill` is `recursive fn`.
- **Folders.** `markdown.goose` and `views.goose` are `site/markdown.goose` and `site/views.goose` (import
  `gweb.site.markdown`, `gweb.site.views`): they belong with `meta`, `template`, `sitemap` and `i18n`, the modules that
  serve page content. `cli/views.goose` is the generator and `cli/structs.goose` the shared scanner. The generated registry is
  `.gweb/views.goose`, `import views;`.
- **`g_meta(i)` returns `gweb::ViewMeta` by value** (flat, about 12 KB), not a reference, so it needs no static storage.
  It is built from literals that gweb read from the source (`LABEL`, `ICON`, `UI`, the fields, the slots). `UI`, `LABEL`,
  `ICON` and `RENAMED` must therefore be string literals; gweb says so at the line. `CHILDREN`, `ROOT_OK`, `IN_NAV` and
  `INDEX` are plain `let`s that `goose-cms` reads by the namespace; the registry does not carry them.
- **`g_form` and `g_parse` return `bool`** (false for an unknown view), and `g_parse` adds a form-level "Unknown view." error.
- **Repeaters** may also be `T[..N]` and `T[>..]`; the limit is 64 items or N.
- **The struct parser** is shared by the form decoders and the views generator (`cli/structs.goose`). `cli/component.goose`
  is not switched to it: its parser is the middle of a type checker (tokens, `Ty`, bit sets) and cannot return a field list
  without a rewrite that the design does not need. The shared scanner is text-level on purpose.
- **Group and repeater items hold no group or repeater**, so every nested form is one level deep.
- **Form names.** `PREFIX + field`; a group adds `group.`, a repeater item `name.K.`, and the item count is the posted
  `name.n`.
- **`import gweb.site.markdown;`** is a default import of pages, layouts and views, so `@gweb::markdown(x)` works with no import.
- **`gweb::reserved_prefixes()`** also lists `sitemap.xml` and `robots.txt` when they are generated.
- **`cache_store_key`** refuses a reply when `ctx.csrf` is set (D7), and ttl 0 means "until `epoch_bump()`" (stored for a year).
  `sitemap_add` writes a placeholder for the base, so `sitemap_base` works before or after it.
- **The minified runtime** was stale at the base commit (banners did not match the sources after the rename). `client/build.sh`
  was run for every module.

## Not done

- `cli/component.goose` does not use the shared scanner (above).
- `gweb lsp` and source maps do not know the generated code appended to a view's file (it follows the user's last line, so line
  numbers hold). The srcmap has no entries for it, as for form decoders.
- Views are not given `gweb check` hints beyond the build errors.
