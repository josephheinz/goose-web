#!/bin/sh
# goose-web's reactive runtime suite (DESIGN-ADDENDUM-12, step 3): client/gwi.js's run/T/A/B against jsdom.
#
#   test/reactive.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/jsdom_dir.sh"
JSDOM_DIR=$DIR exec node "$HERE/reactive_test.mjs"
