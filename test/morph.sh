#!/bin/sh
# goose-web's DOM morph suite (DESIGN-ADDENDUM-9): client/gwi.js's morph against jsdom.
#
#   test/morph.sh            FUZZ=20000 SEED=7 test/morph.sh
#
# The first run installs jsdom into GWEB_TEST_CACHE (default ~/.cache/goose-web-test), so it needs a
# network once. It fails, never skips, when jsdom is missing. release_check.sh does not run it.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
DIR=${GWEB_TEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/goose-web-test}
if [ ! -d "$DIR/node_modules/jsdom" ]; then
  mkdir -p "$DIR"
  npm install --prefix "$DIR" --no-save --no-audit --no-fund jsdom@31.0.0 >&2
fi
JSDOM_DIR=$DIR exec node "$HERE/morph_test.mjs"
