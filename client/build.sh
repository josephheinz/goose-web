#!/bin/sh
# Regenerates every client/NAME.min.js from client/NAME.js for each client/gw*.js
# (DESIGN-ADDENDUM-3 follow-up 1, DESIGN-ADDENDUM-12 section 9). For gweb
# maintainers: needs node and npx. The banner `/* NAME HASH */` carries the FNV-1a
# hash of the source, so test/runtime.sh can tell when a minified file is stale.
# ESBUILD may name a local esbuild 0.28.2 binary.
set -eu
cd "$(dirname "$0")/.."
for src in client/gw*.js; do
  case "$src" in *.min.js) continue ;; esac
  name=$(basename "$src" .js)
  HASH=$(node client/fnv.mjs "$src")
  if [ -n "${ESBUILD:-}" ]; then
    "$ESBUILD" "$src" --minify --format=esm --banner:js="/* $name $HASH */" --outfile="client/$name.min.js"
  else
    npx --yes esbuild@0.28.2 "$src" --minify --format=esm --banner:js="/* $name $HASH */" --outfile="client/$name.min.js"
  fi
done
