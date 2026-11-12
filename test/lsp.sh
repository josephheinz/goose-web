#!/bin/sh
# Language server tests (DESIGN-ADDENDUM-18, Step 2). Plain node, no dependencies. real_test.mjs
# needs `goose` on PATH and ./gweb (goose build -o gweb cli/gweb.goose); it skips otherwise.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
exec node --test "$HERE/lsp/srcmap_test.mjs" "$HERE/lsp/proxy_test.mjs" "$HERE/lsp/real_test.mjs"
