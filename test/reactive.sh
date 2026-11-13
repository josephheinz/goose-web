#!/bin/sh
# gweb's reactive runtime suite (DESIGN-ADDENDUM-12, steps 3 and 5): client/gwi.js's run/T/A/B against jsdom.
#
#   test/reactive.sh
#
# 1. reactive_test.mjs runs hand-written defs shaped like what the compiler emits.
# 2. reactive_dom_test.mjs runs the compiled R*.gshtml components of test/components, and store_dom_test.mjs the
#    RCart store (test/components/stores) with RCartBadge and RCartButton: they need ./gweb (built
#    beside this folder: goose build -o gweb cli/gweb.goose) and skips with a note when there is none.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
. "$HERE/jsdom_dir.sh"
status=0
JSDOM_DIR=$DIR node "$HERE/reactive_test.mjs" || status=1

if [ -x "$ROOT/gweb" ]; then
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-reactive.XXXXXX")
  trap 'rm -rf "$WORK"' EXIT
  mkdir -p "$WORK/app" "$WORK/components"
  echo '<p>reactive suite</p>' > "$WORK/app/page.html"
  for f in "$HERE"/components/R[A-Z]*.gshtml; do
    case "$(basename "$f")" in Fail*|Warn*) ;; *) cp "$f" "$WORK/components/" ;; esac
  done
  mkdir -p "$WORK/stores"
  cp "$HERE"/components/stores/R[A-Z]*.gshtml "$WORK/stores/"
  if "$ROOT/gweb" -C "$WORK" gen >"$WORK/gen.log" 2>&1; then
    JSDOM_DIR=$DIR GW_DIR="$WORK/.gweb/_gw" node "$HERE/reactive_dom_test.mjs" || status=1
    JSDOM_DIR=$DIR GW_DIR="$WORK/.gweb/_gw" node "$HERE/store_dom_test.mjs" || status=1
  else
    cat "$WORK/gen.log"
    echo "FAIL reactive.sh: gweb gen of the R*.gshtml components"
    status=1
  fi
else
  echo "reactive.sh: no ./gweb here, so the compiled components are not run (goose build -o gweb cli/gweb.goose)"
fi
exit $status
