#!/bin/sh
# Regenerates client/gwi.min.js from client/gwi.js (DESIGN-ADDENDUM-3,
# follow-up 1). For goose-web maintainers: needs node and npx. The banner
# carries the FNV-1a hash of gwi.js, so test/islands.sh can tell when the
# minified file is stale. ESBUILD may name a local esbuild 0.28.2 binary.
set -eu
cd "$(dirname "$0")/.."
HASH=$(node client/fnv.mjs client/gwi.js)
if [ -n "${ESBUILD:-}" ]; then
  "$ESBUILD" client/gwi.js --minify --format=esm --banner:js="/* gwi $HASH */" --outfile=client/gwi.min.js
else
  npx --yes esbuild@0.28.2 client/gwi.js --minify --format=esm --banner:js="/* gwi $HASH */" --outfile=client/gwi.min.js
fi
