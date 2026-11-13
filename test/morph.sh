#!/bin/sh
# gweb's DOM morph suite (DESIGN-ADDENDUM-9): client/gwi.js's morph against jsdom.
#
#   test/morph.sh            FUZZ=20000 SEED=7 test/morph.sh
#
# The first run installs jsdom into GWEB_TEST_CACHE (default ~/.cache/gweb-test), so it needs a
# network once. It fails, never skips, when jsdom is missing. release_check.sh does not run it.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/jsdom_dir.sh"
JSDOM_DIR=$DIR exec node "$HERE/morph_test.mjs"
