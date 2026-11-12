<!-- Produced by goose-architect on claude-opus-5-5 (medium) -->
# Design addendum 9: keyed morph (goose-web v0.2.0)

The user asks for keyed morph. List reordering and stable element identity are now requirements.
This replaces the "no keys" decision of DESIGN-ADDENDUM-4, Follow-up 1.

## What I read, and the evidence

Read: `docs/ARCHITECTURE.md` 4.4 and 7, `client/gwi.js`, `client/build.sh`, DESIGN-ADDENDUM-3
Follow-up 2 (points 3 and 7), DESIGN-ADDENDUM-4 sections 6, 9, 10, 12 and Follow-up 1,
`cli/component.goose` (attribute emission, `test_names`), `cli/gweb.goose` (`gw-` handling,
`embed_file` of the runtime, `test_cmd`), `test/components.sh`, `test/fragments.sh`,
`test/release_check.sh`, `examples/shop/components/TodoBox.gshtml`,
`examples/shop/app/fragments/page.html`, `goose-bench/shop/check_site.py` (components block),
`README.md` (fragments rule, limits).

Facts the decisions rest on:

- `morph` is the only DOM writer for components (`swap` in `on`) and fragments (`swap` in `frag`).
- `gweb` embeds `client/gwi.js` and `client/gwi.min.js` at its own build (`embed_file`, gweb.goose
  line 1216). After a runtime change, `gweb` must be rebuilt.
- Attributes with `{expr}` values already work in both compilers (`<li value="{i}">` in
  `test/components/Loops.gshtml`). The component compiler has no attribute allow-list.
- `gweb` has no warning channel. Every build diagnostic is an error.
- `gweb` treats only `gw-target` specially. No check rejects other `gw-` attributes.
- The `gwi.min.js` limit is enforced in one place: `goose-bench/shop/check_site.py` line 207.
- No DOM test harness exists. The only JavaScript tests are `gweb test` parity runs.
- `examples/shop` and `goose-bench` are in the lab repo (`/Users/joeheinz/Documents/goose`), not in
  the goose-web repo.

Prototype evidence (the stopped architect's builder; scratchpad
`/private/tmp/claude-501/-Users-joeheinz-Documents/4ae17d8b-d8e8-4e87-98d8-883f15c4658c/scratchpad/arch-keyed/`):

- `gwi.js` (the first draft) crashed on `key(null)` when the cursor ran off the end. Fixed in
  `gwi.fixed.js` (`a && key(a)`) and `gwi.small.js` (`a?.nextSibling == o && key(a)`).
- `gwi.small.js` passes all 18 cases of `test_morph.mjs` under jsdom 31.0.0, seeds 20260101, 7
  and 99, including a 20,000-case fuzz with shrinking.
- Unkeyed content: 2,000 random pairs give the same HTML, the same node identity by position and
  the same DOM operation count as the current morph.
- Moves: on dup-free fuzz cases, 3,042 of 3,344 were move-minimal (394 root moves against a
  minimum of 55 in total). Named cases: rotate right 1 move, rotate left 1, adjacent swap 1,
  reverse of 5 gives 4 (the minimum), removals and insertions 0.
- Size: `gwi.min.js` 3,133 bytes today (gzip 1,662); with `gwi.small.js` 3,604 bytes (gzip 1,862).
  That is **+471 bytes, 20 bytes over the 3,584 limit**.
- jsdom demo (`demo_check2.mjs`): a focused input inside a moved row stays focused and keeps typed
  text with `force` 0.

Not verified: any real browser. jsdom's focus behaviour on node moves is not proof for Chromium,
Firefox or Safari. Experiment E0 below covers Chromium before the runtime is changed.

## Decisions

### D1. Key attribute: `gw-key`; `id` does not count

**`gw-key="VALUE"` on an element makes it keyed among its siblings. The match key is the tag name
plus the exact attribute string. An empty `gw-key` is the same as no key. `id` is not a key.**

Reason: the name matches the author-written `gw-target`. A page without `gw-key` then morphs
exactly as v0.1, operation for operation; that is the regression guarantee. Index-based ids
(`id="row-{i}"`, common for `<label for>`) would otherwise turn today's in-place patch into a
rebuild, and the focused control would lose focus.

Rejected:
- `id` as an implicit key: silent behaviour change on existing pages with changing ids.
- `key` (bare, as in React): not a recognisable framework attribute in HTML; collides with nothing today but reads like a real attribute.
- `data-gw-key` or `data-key`: longer, and the `data-` prefix is used for compiler-emitted attributes (`data-on-*`, `data-bind`), not author-written ones.
- Key without the tag name: a tag change under one key would patch a `<li>` into a `<div>`.

Risks: `gw-key` stays in the served HTML (harmless, about 12 bytes per keyed element). HTML
validators flag the unknown attribute, as they already flag `gw-target`.

### D2. How templates and components emit keys: plain attributes, no new syntax

**Authors write `<li gw-key="{t.id}">` in `page.html`, layouts and `.gshtml` files alike. No
compiler change.** Keys are scoped to one parent: a keyed element that moves to another parent is
rebuilt.

Reason: both compilers already emit attribute values with `{expr}` and escape them the same way,
and parity covers components.

Rejected:
- A `{#for t in s.items key t.id}` clause: compiler work in two compilers and a new syntax rule, for the same output.
- Auto-keying `{#for}` by index: index keys move nothing; identity follows the position, which is the unkeyed behaviour.

Risks: none beyond D6 (author mistakes in key values).

### D3. Algorithm: the tested prototype, unchanged in behaviour

**Adopt `gwi.small.js`'s `key` helper and `morph`. The text is given below; the builder pastes it
into `client/gwi.js` in place of the current `morph` and its comment.**

Steps, for one parent:
1. Collect the keys of the new children. A key seen twice reports one `gw:error` through `oops`.
2. Walk the old children once. An old keyed child whose key is wanted and not yet claimed goes
   into a map; any other old keyed child (unwanted, or a duplicate) is removed now.
3. Walk the new children with a cursor `a` over the old children:
   - A keyed new child takes its old match from the map. If the match is not at the cursor, it is
     moved before the cursor, except when the cursor is a keyed child immediately followed by the
     match; then the cursor steps over it, and that child is placed when its own turn comes.
   - An unkeyed new child takes the next unkeyed old child at or after the cursor, skipping keyed
     ones. This is the v0.1 positional rule, applied among unkeyed nodes only.
   - No match: the new node is inserted before the cursor.
   - A match is patched exactly as today: replace on another node name, text update, attribute
     sync, recurse, then `value` and `checked` with the Addendum 3 focus rule.
4. Old nodes left after the cursor are removed.

Complexity: O(n) time per child list (one Set, one Map, two extra passes). Every element pays two
small allocations per morph. Moves: at most one per keyed child. Minimal for rotations, swaps,
inserts and removals when siblings are adjacent; with whitespace text between keyed siblings
(the usual `{#for}` output) a swap costs 2 moves instead of 1.

Byte cost: about +471 bytes minified (3,133 to about 3,604), +200 gzip.

The reference text (from `gwi.small.js`, tested as described above):

```js
// A child's key is its tag plus its gw-key; a tag change under the same gw-key is a different child.
const key = (n, k = n.getAttribute?.("gw-key")) => k && n.nodeName + " " + k;

// Makes from's children match to's. A child with gw-key is matched to the old child with the same key
// wherever it is; the others are matched in order among themselves. value and checked sync after
// recursing so a <select> has its new options first; the focused control keeps its value unless force is set.
function morph(from, to, force) {
  const want = new Set(), old = new Map();
  for (const n of to.childNodes) {
    const k = key(n);
    if (k) want.has(k) ? oops("duplicate gw-key " + k) : want.add(k);
  }
  // Old keyed children that are not wanted leave first, so every keyed child still here is claimed below.
  for (const n of [...from.childNodes]) {
    const k = key(n);
    if (k) want.has(k) && !old.has(k) ? old.set(k, n) : n.remove();
  }
  let a = from.firstChild, b = to.firstChild;
  while (b) {
    const nb = b.nextSibling, k = key(b);
    let o;
    if (k) {
      o = old.get(k);
      old.delete(k);
      if (o && o != a) {
        // A keyed child right before its match is stepped over and placed when its own turn comes;
        // this turns a swap or a move to the end into one move.
        if (a?.nextSibling == o && key(a)) a = o;
        else {
          // insertBefore blurs a focused control inside the moved child.
          const f = D.activeElement;
          from.insertBefore(o, a);
          if (f != D.activeElement) f.focus();
        }
      }
    } else {
      while (a && key(a)) a = a.nextSibling;
      o = a;
    }
    if (!o) from.insertBefore(b, a);
    else {
      if (o == a) a = a.nextSibling;
      if (o.nodeName != b.nodeName) o.replaceWith(b);
      else if (o.nodeType != 1) { if (o.data != b.data) o.data = b.data; }
      else {
        for (const { name } of [...o.attributes]) if (!b.hasAttribute(name)) o.removeAttribute(name);
        for (const { name, value } of b.attributes) if (o.getAttribute(name) != value) o.setAttribute(name, value);
        morph(o, b, force);
        if ("form" in o) {
          if ((o != D.activeElement || force) && o.value != b.value) o.value = b.value;
          o.checked = b.checked;
        }
      }
    }
    b = nb;
  }
  while (a) { b = a.nextSibling; a.remove(); a = b; }
}
```

`oops` is a function declaration further down the file and is hoisted; it stays where it is.

Rejected:
- Longest-increasing-subsequence move minimisation: about 150 more bytes for fewer moves on lists of tens of items, where the extra moves cost nothing visible.
- idiomorph-style id sets over the whole subtree (match across parents): several hundred bytes more and a new matching model to test.
- Merging the Set and the Map into one map (saves about 20 bytes): untested, and 20 bytes does not buy the headroom D4 needs.
- A step-over that skips whitespace (`nextElementSibling`): it would skip unkeyed elements too and leave them behind; untested.
- `Node.moveBefore` (keeps focus and iframe state without a refocus): not in every target browser, so it needs the `insertBefore` fallback anyway, and the fallback is the path jsdom can test. Candidate for a later version.

Risks:
- Moving a node by `insertBefore` reloads an `<iframe>` and restarts CSS animations inside it, and may reset scroll offsets of scrolled elements inside the moved node. Documented, not handled.
- The refocus fires `blur`/`focusout`/`focus`/`focusin`. No goose-web listener uses them. Whether a browser fires `change` on the move is experiment E0.
- `f.focus()` scrolls the refocused control into view. A row moved off screen while focused scrolls the page to it. Accepted: the user is working in that control.

### D4. Size limit: 4,096 bytes

**`gwi.min.js` may be at most 4,096 bytes. `check_site.py` line 207 changes to 4,096.**

Reason: the tested variant is 3,604 bytes, already over 3,584. Addendum 7 adds a header to the
fragment fetch at the same time. Getting under 3,584 would mean dropping duplicate reporting or
the refocus, and both are requirements here. 4,096 leaves about 490 bytes for Addendum 7 and v0.2
fixes.

Rejected:
- Keep 3,584 and drop the duplicate `oops` (about 40 bytes): duplicates would fail silently.
- Keep 3,584 and drop the refocus: a focused control in a moved row loses focus, which is the bug keys exist to fix.
- A separate keyed-morph module loaded on demand: a second request on every page that uses keys.

Risks: the limit is a budget, not a measurement of harm. gzip 1,862 bytes is what users download.

### D5. Mixed keyed and unkeyed siblings

**Allowed. Keyed children match by key anywhere among their siblings. Unkeyed children match by
position among the unkeyed children only. A keyed child never takes an unkeyed child's slot.**

Reason: this is what makes a keyed conditional element safe before an input (prototype cases 9a,
9b), and what lets a list sit between an unkeyed heading and footer (case 15).

Rejected:
- All-or-nothing (keys used only when every child is keyed): whitespace text nodes from templates would always disable keys.

Risks: an unkeyed element that comes and goes still shifts the unkeyed siblings after it. The
README rule (D8) says so.

### D6. Duplicate and missing keys

- **Duplicate key among new siblings:** the first gets the old element; later ones are built new.
  Each morph reports `duplicate gw-key TAG VALUE` once per duplicate through `oops`, so `gweb dev`
  shows the overlay and production logs to the console. The DOM is still correct.
- **Duplicate key among old siblings** (only possible from server HTML): the first is kept, the
  rest are removed. No report.
- **Missing or empty key:** unkeyed (D5).
- **Same key, other tag:** a different element; the old one is removed, the new one built.

Reason: never leave the DOM wrong; tell the author in development.

Rejected:
- Throwing on duplicates: a component would roll back state on a markup mistake, and a fragment would not render at all.
- Silent duplicates: the identity bug is invisible until focus jumps.

Risks: a component with duplicate keys reports on every keystroke. That is noisy on purpose.

### D7. No build warning for an unkeyed `{#for}`

**No warning, no error.**

Reason: `gweb` has no warning channel, and most `{#for}` loops are server pages that never morph,
append-only lists, or text loops (`{#for i in 2..n}[{i}]{/for}`) that cannot be keyed. A rule
without false positives needs HTML structure, which `gweb` does not parse (Addendum 4 Follow-up 1
already rejected structure guesses).

Rejected:
- Error on an unkeyed `{#for}` in `.gshtml` only: false errors on text loops and append-only lists.
- A new warning channel for this one case: a CLI feature larger than the problem.

Risks: authors forget keys. The README rule and the TodoBox example are the mitigation.

### D8. The Addendum 4 Follow-up 1 author rule is replaced

New rule (README, Fragments section; it applies to components too):

> The morph matches keyed elements by `gw-key` and other nodes by position. Give `gw-key`, unique
> among its siblings, to every item of a list that can be reordered or lose an item other than the
> last (`<li gw-key="{t.id}">`), and to an element that comes and goes in front of other siblings.
> An unkeyed element that comes and goes must be the last child of its parent.

The fragments demo keeps its trailing error `<span>`; it still satisfies the rule and needs no
churn.

Rejected:
- Keep the old rule as the only rule: it cannot express reordering.
- Drop all rules: unkeyed conditional elements still shift their siblings.

### D9. Parity

**No compiler change. Add one parity fixture, `test/components/Keys.gshtml`, so `gweb test`
compares keyed markup, including a string key that needs escaping, between Goose and JavaScript.**

The fixture (builder writes it):
- `struct Item { id: i64, name: u8[..40] }`, `struct State { err: bool, draft: u8[..40], items: Item[>..<] }`.
- Markup: `{#if s.err}<span gw-key="err">bad</span>{/if}<input bind:value="draft">` then
  `<ul>{#for t in s.items}<li gw-key="{t.id}" title="{t.name}">{t.name}</li>{/for}</ul>` and one
  `<p gw-key="{t.name}">` loop over the same items.
- `test_keys`: push three items, one named `a"b&<c'`. `test_swap`: swap items 0 and 2 through a
  temporary copy, set `err`.

`components.sh` stays at 41 checks (the fixture is not `Fail*`); the `gweb test` case count rises.

### D10. Tests: a new jsdom harness, `test/morph.sh`

**New `test/morph.sh` and `test/morph_test.mjs`, with a frozen copy of the v0.1 morph as the
oracle, `test/morph/v1.js`.**

- `morph.sh` installs `jsdom@31.0.0` once into `${GWEB_TEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/goose-web-test}`
  (`npm install --prefix DIR --no-save --no-audit --no-fund jsdom@31.0.0`) when
  `DIR/node_modules/jsdom` is missing, then runs `node test/morph_test.mjs` with `JSDOM_DIR=DIR`.
  It fails, never skips, when jsdom cannot be installed.
- `morph_test.mjs` loads jsdom with `createRequire(JSDOM_DIR + "/")`. It extracts from
  `client/gwi.js` the text from the line starting `const key =` to the first line that is exactly
  `}` after `function morph(`, and builds it with `new Function("D", "oops", src + "; return morph;")`
  against the jsdom document, with an `oops` that records calls. `test/morph/v1.js` holds today's
  `morph` verbatim and is loaded the same way.
- Output: `PASS name` / `FAIL name` lines, then `morph.sh: N passed, M failed`, exit non-zero on a
  failure. `FUZZ` (default 5,000) and `SEED` (default 20260101) come from the environment.

Cases (port them from the prototype `test_morph.mjs`; the move counts are measured there):

| # | Case | Asserts |
|---|---|---|
| 1 | Unkeyed equivalence, 2,000 random pairs | same HTML, same identity by position, same op count as v1 |
| 2 | Empty `gw-key` | same ops and identity as v1 |
| 3 | Rotate right 1,2,3,4,5 to 5,1,2,3,4 | identity of all five, 1 move |
| 4 | Rotate left to 2,3,4,5,1 | identity, 1 move |
| 5 | Adjacent swap | identity, 1 move |
| 6 | Remove first of five | identity of the rest, 0 moves |
| 7 | Remove three in the middle | identity, 0 moves |
| 8 | Insert at front and middle | identity, 0 moves |
| 9 | Reverse of five | identity of all five |
| 10 | Keyed conditional before an unkeyed input, shown then hidden | the input is the same node both times |
| 11 | Keyed conditional in the middle | label and input keep identity |
| 12 | Duplicate key in new | correct HTML, exactly one `oops` containing `duplicate gw-key` |
| 13 | Duplicate key in old only | first kept, no `oops` |
| 14 | Same key, other tag | rebuilt |
| 15 | Whitespace text between keyed items, swapped | identity, at most 2 moves |
| 16 | Nested keyed lists | outer and inner identity |
| 17 | Keyed list between unkeyed heading and footer | heading and footer keep identity |
| 18 | Key with `"`, `&`, `<` in the value | matched |
| 19 | Focused text input in a moved row, `force` 0 | still `activeElement`, typed value kept |
| 20 | Same as 19 with `force` 1 | still focused, value replaced |
| 21 | Fuzz `FUZZ` cases, nested keyed and unkeyed, shrinking on failure | correct HTML; identity for every surviving key when keys are unique |

`release_check.sh` does not run `morph.sh`: it rehearses a release without a network.

Rejected:
- Exporting `morph` from `gwi.js` for tests: public API and bytes for a test hook.
- A hand-written fake DOM: focus and node identity semantics would be ours, not a browser's.
- Committing `node_modules` or a `package.json` to goose-web: goose-web has no npm project today.

Risks: the text extraction depends on `const key =` staying the first line and `}` closing the
function at column 0. A failure to extract is a test failure with a clear message, not a pass.

### D11. Demo: TodoBox keeps open items above done ones

**`examples/shop/components/TodoBox.gshtml`:**
- `<li gw-key="{t.id}" class="...">`.
- A new non-handler function `open_first(s: State&)`: a stable insertion sort that moves done
  items below open ones and keeps the order within each group (adjacent swaps through a temporary
  `Item` copy, a `while` loop). `toggle` calls it after flipping `done`.
- A `test_sort` test function: four items, toggle the first and third, assert by rendering (the
  parity run compares Goose and JS output).

Checking a box moves its row to the bottom; unchecking moves it back. The second direction moves
the focused row itself, so it exercises the refocus.

**`examples/shop/app/fragments/page.html`:** the `<li>` line becomes `<li gw-key="{t.id}">…`.
Nothing else changes in that file. Server order is unchanged; the demo is identity on Remove.

Rejected:
- A separate "Sort" button: the reorder would never move a focused control, so the focus path would go untested in the browser.
- A server-side reorder in `/fragments`: changes the shop state code that other addenda may be editing.

Risks: `/components` behaviour changes (a checked item moves). `check_site.py` asserts only the
initial empty state and still passes.

## Files and coordination

| File | Repo | Change |
|---|---|---|
| `client/gwi.js` | goose-web | Only `morph()`, its comment, and the new `key` helper directly above it. |
| `client/gwi.min.js` | goose-web | Regenerated by `client/build.sh`, never edited. |
| `test/morph.sh`, `test/morph_test.mjs`, `test/morph/v1.js` | goose-web | New. |
| `test/components/Keys.gshtml` | goose-web | New. |
| `docs/ARCHITECTURE.md` | goose-web | Section 4.4 bullets and the closing paragraph; the morph line in section 7; the `test/morph.sh` row in section 6. |
| `README.md` | goose-web | The morph bullet in "Fragments" (D8 text); the "No keys" sentence in "Limits (v1)"; one line naming `test/morph.sh` where the suites are listed. |
| `CHANGELOG.md` | goose-web | One bullet under `## v0.2.0` (create the heading if absent; other addenda add their own bullets). |
| `examples/shop/components/TodoBox.gshtml` | lab | D11. |
| `examples/shop/app/fragments/page.html` | lab | The `<li` line only. |
| `goose-bench/shop/check_site.py` | lab | Size line to 4,096; two new checks (step B2). |

Not touched: `cli/*.goose`, `web.goose`, `form.goose`, `VERSION`, `test/fragments.sh`,
`test/templates.sh`, `test/release_check.sh`.

Parallel work:
- **Addendum 7 (CSRF)** edits `frag()` in `client/gwi.js`. This design edits only `morph()` and the
  `key` helper beside it. Whoever merges second reruns `client/build.sh` and rebuilds `gweb`; a
  `gwi.min.js` conflict is resolved by regenerating, never by hand. If Addendum 7 also changes the
  `check_site.py` size line, keep 4,096 unless its number is higher. If a top-level `key` already
  exists in `gwi.js` after a merge, stop and report.
- **Addendum 7** may add a hidden token input to the `/fragments` form. Both edits are line-local;
  keep both.
- **Addendum 8 (catch-all routes)** owns `cli/gweb.goose`. Nothing here touches it.
- **Addendum 10 (SQLite writes)**: no overlap.

## Experiments

**E0, before step A2 (no commit).** Focus and events when a focused control moves, in Chromium
(the browser pane).
1. Copy the prototype `demo.html` from the old scratchpad to your own scratchpad. Its inline
   `morph` is the `gwi.small.js` text.
2. Add capture-phase listeners on `document` for `blur`, `focusout`, `focus`, `focusin`, `change`
   and `input` that log `type` and the target's row key.
3. Focus the text input in row 3, type `abc`, put the caret after `a` (`setSelectionRange(1, 1)`),
   and trigger a reorder that moves row 3 itself (not stepped over): for example new order 3,1,2,4,5.
4. Record: `document.activeElement` is the same input; its value; `selectionStart`; the event log.

Outcomes:
- Same element focused, value kept, no `change` or `input` logged: the design stands.
- `selectionStart` changed: the design stands; add "the caret may move when a focused control's
  row moves" to README Limits in step A4.
- A `change` or `input` event fires during the move: **stop and report to the architect.** The
  component listener would run a second render and morph inside the first. Do not add a guard on
  your own.
- Focus is not on the input afterwards: **stop and report.**

**E1, at step C1.** The same check on the real runtime through TodoBox (see the browser lines).

## Builder plan (Sonnet 5.5, medium effort)

Rules for every step: one commit per step, in the repo named. No comments that restate code,
narrate history or cite design documents; why-comments only. Do not change files outside the step.
Build `gweb` with `goose build -o gweb cli/gweb.goose` (in goose-web) whenever `client/` changed,
because `gweb` embeds the runtime.

Baseline before starting: components.sh 41, templates.sh 33, fragments.sh 69, cookie_test 59,
test_net 142, release_check.sh passing, `check_site.py --components --cookies --fragments`
passing, `/products/42` byte-identical. Record the numbers; any later drop is a failure.

### Phase A: goose-web repo

**E0** (above). No commit. Report the result before A2.

**A1. Morph harness on the current runtime.**
- Add `test/morph.sh`, `test/morph_test.mjs`, `test/morph/v1.js` (D10). `v1.js` is today's
  `morph` copied verbatim from `client/gwi.js`, including its comment.
- In this step the extraction falls back to `function morph(` when no `const key =` line exists,
  and only cases 1 and 2 run, since the current morph has no keys. Gate the other cases on the
  presence of `const key =` in `client/gwi.js`.
- Checks: `test/morph.sh` prints 2 passed, 0 failed; a second run does not reinstall jsdom.
- Commit: `goose-web: test/morph.sh, a jsdom harness for the morph`.

**A2. Keyed morph.**
- In `client/gwi.js`, replace the comment and body of `morph` with the D3 text, and add the `key`
  helper and its comment directly above. Touch nothing else in the file.
- Remove the A1 gating so all 21 cases run.
- Run `client/build.sh`. Rebuild `gweb`.
- Checks:
  - `test/morph.sh`: 21 passed. Also run with `FUZZ=20000` and with `SEED=7` and `SEED=99`.
  - `wc -c client/gwi.min.js`: report it; it must be at most 4,096 (expected about 3,604).
  - `test/components.sh`: 41 passed (the banner hash check proves `gwi.min.js` is current).
  - `test/fragments.sh`: 69. `test/templates.sh`: 33.
- Commit: `goose-web: keyed morph with gw-key`.

**A3. Parity fixture.**
- Add `test/components/Keys.gshtml` (D9).
- Checks: `test/components.sh` 41 passed, and its `gweb test` line reports more cases than before
  with none failing. If a test function does not compile in the client subset, simplify the
  Goose (not the compilers) and report what you changed.
- Commit: `goose-web: parity fixture for keyed markup`.

**A4. Documents.**
- `docs/ARCHITECTURE.md` 4.4: replace the "There are no keys" paragraph and the bullets with a
  description of D3 steps and D5, and the D8 rule. Section 7: replace the morph limit with "a moved
  keyed element is reinserted, which reloads an iframe inside it". Section 6: add the
  `test/morph.sh` row.
- `README.md`: the D8 rule in place of the old morph bullet; replace "No keys in the DOM morph, so
  removing a list item reuses the nodes after it." with the moved-element sentence; name
  `test/morph.sh` with the other suites. Add the caret sentence only if E0 showed it.
- `CHANGELOG.md`: under `## v0.2.0`, "Keyed morph: `gw-key` keeps element identity and focus when
  list items move, appear or disappear."
- Checks: `grep -n "no keys\|No keys\|without keys" README.md docs/ARCHITECTURE.md client/gwi.js`
  finds nothing; `test/components.sh` still 41 (documents only).
- Commit: `goose-web: document gw-key`.

### Phase B: lab repo (`/Users/joeheinz/Documents/goose`)

Run the shop with the `gweb` rebuilt in A2, the same way the existing `check_site.py` runs do.

**B1. Shop demo.**
- `examples/shop/components/TodoBox.gshtml`: D11 (`gw-key`, `open_first`, `toggle` calls it,
  `test_sort`).
- `examples/shop/app/fragments/page.html`: `<li gw-key="{t.id}">` on the existing `<li>` line only.
- Checks: `gweb -C examples/shop test` passes, including `test_sort` and `test_basic`;
  `gweb -C examples/shop build` succeeds; `check_site.py --components --cookies --fragments`
  passes; `/products/42` byte-identical.
- Commit: `shop: keyed TodoBox rows keep open items first; keyed fragment list`.

**B2. check_site.py.**
- Line 207: `3,584`/`3584` become `4,096`/`4096`.
- In the components block: `/_gw/TodoBox.js` contains `gw-key`.
- In the fragments block: `/fragments` contains `<li gw-key="`.
- Checks: `check_site.py --components --cookies --fragments` passes with the two new checks;
  `bench_shop.py` still runs.
- Commit: `goose-bench: gwi.js limit 4,096 and gw-key checks`.

### Phase C: browser verification (no commit)

**C1.** Run the browser lines below against `gweb dev` in the browser pane, plus all Addendum 4
browser lines. Report each line as pass or fail with what you saw. A failure in the E1 lines
(the first two below) blocks the release; report to the architect.

**C2.** Rerun every suite in the baseline list and `test/morph.sh`; report the counts.

## Browser test lines

On `/components` (TodoBox):
- E1: add `a`, `b`, `c`. Install capture listeners for `change`, `input`, `focus`, `blur` that log
  to `window.__ev`. Tab to `a`'s checkbox and press Space: `a`'s row moves to the bottom, the same
  checkbox element (held in a variable before) is `document.activeElement`, and the log holds one
  `change` (the Space press).
- E1: press Space again: `a`'s row moves back to the top (this moves the focused row itself); the
  checkbox is still focused; one more `change` only.
- Hold `b`'s `<li>` in a variable, check `a` and `c`: the `<li>` for `b` is the same node and now
  first.
- Type in the "What needs doing?" input with three items present, then press Enter: the item is
  added, the input is empty and focused (Addendum 3 Follow-up 2 line, unchanged).
- Counter and Qty still work.

On `/fragments`:
- Hold the third item's `<li>` in a variable. Remove the first item: the held `<li>` is the same
  node, still connected.
- Done and Undo change only that item; focus behaviour as in the Addendum 4 lines.

In `gweb dev`, a component with a duplicate key:
- Temporarily give two TodoBox rows the same key (edit `gw-key="1"`), add two items: the overlay
  shows `duplicate gw-key LI 1`, and the list still renders both items. Revert the edit.

## Risks

- **Browser coverage:** jsdom and Chromium only. Firefox and Safari focus behaviour on node moves is
  unverified; the refocus covers a blur, but not an extra `change` (E0 checks Chromium only).
- **Moved nodes lose some live state:** iframes reload, animations restart, inner scroll offsets may
  reset. Documented.
- **Move count is not minimal** with whitespace between keyed siblings. Correct but up to about
  twice the minimum moves; invisible at shop sizes.
- **Every morph allocates a Set and a Map per element.** Measured only for correctness, not speed.
  Large fragments (hundreds of rows) should be timed once in the browser pane if they appear.
- **Duplicate keys** spam `gw:error` in a component until fixed. Intentional.
- **Parallel merge with Addendum 7:** the minified file and the size line are shared; the
  coordination rules above apply.
- **The harness needs the network once** (npm). Offline machines without the cache fail `morph.sh`.

## Decisions for the user

1. **The name `gw-key`**, and that `id` is not a key.
2. **The size limit 4,096 bytes** (from 3,584). The alternative is 3,584 with no duplicate reporting.
3. **TodoBox changes behaviour:** a checked item moves to the bottom.
4. **No build warning** for unkeyed loops.
5. **`test/morph.sh` fetches jsdom 31.0.0 from npm** into a user cache on first run, and
   `release_check.sh` does not run it.
6. **E0 outcome:** if Chromium fires `change` on a moved control, the design returns to the
   architect before the runtime changes.
