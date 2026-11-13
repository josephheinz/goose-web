#!/bin/sh
# gweb's fragment suite (DESIGN-ADDENDUM-14): client/gwi.js frag() against jsdom.
#
#   test/frag.sh
#
# The first run installs jsdom into GWEB_TEST_CACHE (default ~/.cache/gweb-test), so it needs a
# network once. It fails, never skips, when jsdom is missing.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
DIR=${GWEB_TEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/gweb-test}
if [ ! -d "$DIR/node_modules/jsdom" ]; then
  mkdir -p "$DIR"
  npm install --prefix "$DIR" --no-save --no-audit --no-fund jsdom@31.0.0 >&2
fi
JSDOM_DIR=$DIR exec node "$HERE/frag_test.mjs"
