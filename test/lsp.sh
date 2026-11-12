#!/bin/sh
# Language server tests (DESIGN-ADDENDUM-18, Step 2). Plain node, no dependencies, no goose compiler.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
exec node --test "$HERE/lsp/srcmap_test.mjs" "$HERE/lsp/proxy_test.mjs"
