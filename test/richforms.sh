#!/bin/sh
# gweb's generated-form suite for 1.1: repeater item buttons, the typed text of a failed field, help text linked to
# its control (g_form_req), and ITEM_LABEL.
#
#   GOOSE=/path/to/goose test/richforms.sh
#
# 1. test/richforms/app runs under gweb test (tests/rich.goose).
# 2. Each build error, in a copy, must fail gweb gen with its message at its line.
#
# Needs gweb built beside this folder (goose build -o gweb cli/gweb.goose). Starts no server.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-richforms.XXXXXX")
trap 'rm -rf "${WORK:?}"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
show() { echo "$1" | sed 's/^/    /'; }

cp -R "$HERE/richforms/app" "$WORK/ok"
if out=$("$GWEB" -C "$WORK/ok" test 2>&1); then
  case "$out" in *"routes: 4 tests, "*" 0 failed"*) ok ;; *) bad "gweb test did not print 'routes: 4 tests ... 0 failed':"; show "$out" ;; esac
else
  bad "gweb test of the rich forms failed:"; show "$out"
fi

expect_fail() {   # expect_fail NAME WANT
  if out=$("$GWEB" -C "$WORK/$1" gen 2>&1); then bad "$1: gweb gen succeeded"
  else case "$out" in *"$2"*) ok ;; *) bad "$1: wanted '$2', got:"; show "$out" ;; esac; fi
}
cp -R "$HERE/richforms/app" "$WORK/e1"
sed 's/ITEM_LABEL = "label"/ITEM_LABEL = "n"/' "$HERE/richforms/app/views/widgets/Card.goose" > "$WORK/e1/views/widgets/Card.goose"
expect_fail e1 'views/widgets/Card.goose:4: error: ITEM_LABEL: "n" is not a text field of Row'
cp -R "$HERE/richforms/app" "$WORK/e2"
sed 's/ITEM_LABEL = "label"/ITEM_LABEL = "nope"/' "$HERE/richforms/app/views/widgets/Card.goose" > "$WORK/e2/views/widgets/Card.goose"
expect_fail e2 'ITEM_LABEL: "nope" is not a text field of Row'
cp -R "$HERE/richforms/app" "$WORK/e3"
printf 'import std;\nlet ITEM_LABEL = "x";\nstruct Props { a: u8[..10] = "" }\n' > "$WORK/e3/views/widgets/Card.goose"
expect_fail e3 'views/widgets/Card.goose:2: error: ITEM_LABEL needs a repeater in Props'
cp -R "$HERE/richforms/app" "$WORK/e4"
printf 'import std;\nstruct Props { a: u8[..10] = "" }\nfn form_req() {}\n' > "$WORK/e4/views/widgets/Card.goose"
expect_fail e4 'fn form_req is generated for every view; rename yours'

echo "richforms.sh: $pass of $((pass + fail)) checks passed"
[ "$fail" -eq 0 ]
