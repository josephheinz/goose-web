#!/bin/sh
# tools/migrate-v1.sh on the v0.7.0 fixtures and the tutorial app (v1.0).
#
#   GOOSE=/path/to/goose test/migrate.sh
#
# Takes test/ and docs/site/tutorial from the v0.7.0 tag (or MIGRATE_REF, or main) with git archive, runs the script on a copy
# and checks that:
# 1. the old names are gone and the new ones are in: stream_write, stream_end, socket_send, the .gweb paths, --access-log;
#    --log-format and --log-level are untouched; the reminders are printed; a second run changes nothing;
# 2. the push app, which calls renamed names, does not build with this gweb as it was, and every app builds once migrated: test/push/site, the CMS
#    fixture (a package, a module, views, SQLite), the tutorial app and test/auth/site.
#
# Needs git, and gweb built beside this folder (goose build -o gweb cli/gweb.goose).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
if [ ! -x "$GWEB" ]; then echo "migrate.sh: $GWEB is missing; build it first: goose build -o gweb cli/gweb.goose" >&2; exit 2; fi
REF=""
for r in "${MIGRATE_REF:-}" v0.7.0 main; do
  [ -n "$r" ] && git -C "$ROOT" rev-parse --verify -q "$r^{commit}" >/dev/null 2>&1 && { REF=$r; break; }
done
if [ -z "$REF" ]; then echo "migrate.sh: no v0.7.0 tag or main branch here; skipped"; exit 0; fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-migrate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { if [ "$1" = ok ]; then ok; else bad "$2"; fi; }
show() { echo "$1" | sed 's/^/    /'; }

mkdir "$WORK/old"
git -C "$ROOT" archive "$REF" test docs/site/tutorial | tar -x -C "$WORK/old"
cp -R "$WORK/old" "$WORK/new"
cp -R "$WORK/old" "$WORK/again"

# 1. The rewrite.
sh "$ROOT/tools/migrate-v1.sh" "$WORK/new" 2>"$WORK/notes.txt"; rc=$?
check "$([ "$rc" = 0 ] && echo ok)" "migrate-v1.sh exits 0"
check "$(! grep -rIl 'gooseweb' "$WORK/new" --exclude='*.mjs' | grep -q . && echo ok)" "no .gooseweb is left anywhere in the migrated tree"
check "$(grep -rIq '^\.gweb/$' "$WORK/new/docs/site/tutorial/notes/.gitignore" && echo ok)" "the tutorial's .gitignore names .gweb/"
old_names=$(grep -rIn 'gweb::\(write\|end\|send\|info\|warn\|debug\|error\|field\|emit\|render\|log\|count\|gauge\)\b' "$WORK/new" | grep -v '/docs/site/tutorial/.*\.md:' || true)
check "$([ -z "$old_names" ] && echo ok)" "no old function name is left"; [ -z "$old_names" ] || show "$old_names"
check "$(grep -q 'gweb::stream_write(s, "one' "$WORK/new/test/push/site/app/export/route.goose" && grep -q 'gweb::stream_end(ctx, s)' "$WORK/new/test/push/site/app/export/route.goose" && echo ok)" "stream_write and stream_end"
check "$(grep -q 'gweb::socket_send(ctx, id' "$WORK/new/test/push/site/app/socket.goose" && echo ok)" "socket_send"
check "$(grep -q 'gweb::log_field(e, "order_id"' "$WORK/new/test/ops_unit.goose" && grep -q 'gweb::log_event(ctx, gweb::Level.Info' "$WORK/new/test/ops_unit.goose" && grep -q 'gweb::log_render(e, out)' "$WORK/new/test/ops_unit.goose" && echo ok)" "log_field, log_event and log_render"
check "$(grep -q 'gweb::_new_ctx(' "$WORK/new/test/cookie_test.goose" && ! grep -q 'gweb::new_ctx' "$WORK/new/test/cookie_test.goose" && echo ok)" "an internal name gets its underscore"
check "$(grep -q -- '--metrics --access-log --log-format json' "$WORK/new/test/ops.sh" && ! grep -q -- ' --log ' "$WORK/new/test/ops.sh" && echo ok)" "--log is --access-log in a script, --log-format is untouched"
check "$(grep -q -- '--log-format' "$WORK/new/test/ops_unit.goose" && echo ok)" "--log-format and --log-level stay"
check "$(grep -q 'cookie_or' "$WORK/notes.txt" && grep -q 'GWEB_TRUST_PROXY' "$WORK/notes.txt" && echo ok)" "the reminders about cookie_or and GWEB_TRUST_PROXY are printed"
sh "$ROOT/tools/migrate-v1.sh" "$WORK/again" 2>/dev/null
sh "$ROOT/tools/migrate-v1.sh" "$WORK/again" 2>/dev/null
check "$(diff -r "$WORK/new" "$WORK/again" >/dev/null && echo ok)" "a second run changes nothing"
# A file argument works too.
printf 'gweb::write(s, x); gweb::info(ctx, "a"); /var/.gooseweb/server --log\n' > "$WORK/one.sh"
sh "$ROOT/tools/migrate-v1.sh" "$WORK/one.sh" 2>/dev/null
check "$([ "$(cat "$WORK/one.sh")" = 'gweb::write(s, x); gweb::info(ctx, "a"); /var/.gweb/server --access-log' ] && echo ok)" "a .sh file argument: paths and flags only"
printf 'gweb::write(s, x); gweb::info(ctx, "a"); gweb::form_int(req, "id"); gweb::form_int(req, "a", f.a, errs, true);\n' > "$WORK/one.goose"
sh "$ROOT/tools/migrate-v1.sh" "$WORK/one.goose" 2>/dev/null
check "$([ "$(cat "$WORK/one.goose")" = 'gweb::stream_write(s, x); gweb::log_info(ctx, "a"); gweb::form_int(req, "id"); gweb::form_i64(req, "a", f.a, errs, true);' ] && echo ok)" "a .goose file: the reader form_int stays, the decoder is form_i64"

# 2. Builds.
if [ -z "${GOOSE:-}" ] && ! command -v goose >/dev/null 2>&1; then
  echo "migrate.sh: no goose compiler (set GOOSE); the builds are skipped"
else
  # The CMS fixture's package comes from a path here: its gweb.packages names ../cms.
  for site in test/push/site test/cmsready/site docs/site/tutorial/notes test/auth/site; do
    # Only the push fixture is checked in its old form: it calls renamed public names. The others use internals.
    if [ "$site" = test/push/site ]; then
      if out=$("$GWEB" -C "$WORK/old/$site" build 2>&1); then bad "$site: v0.7.0 code builds with names that moved"; else ok; fi
    fi
    if out=$("$GWEB" -C "$WORK/new/$site" build 2>&1); then ok; else bad "$site: the migrated app does not build"; show "$(echo "$out" | tail -n 12)"; fi
  done
fi

echo "migrate.sh: $pass of $((pass + fail)) checks passed"
[ "$fail" -eq 0 ]
