#!/bin/sh
# goose-web's client runtime suite (DESIGN-ADDENDUM-12, section 9). Node only.
#
#   test/runtime.sh
#
# 1. Each client/*.min.js carries the FNV-1a hash of its source in its banner
#    (client/build.sh writes it), so a stale minified file fails.
# 2. Each existing .min.js is under its byte ceiling.
# 3. test/morph.sh and test/reactive.sh pass.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# name ceiling; later steps add gwc 768, gwn 1536, gwt 768, gwe 768.
CEILINGS="gwi 4096
gwh 512
gwf 1536
gwl 768"

for src in "$ROOT"/client/gw*.js; do
  case "$src" in *.min.js) continue ;; esac
  name=$(basename "$src" .js)
  min="$ROOT/client/$name.min.js"
  if [ ! -f "$min" ]; then bad "client/$name.min.js is missing: run client/build.sh"; continue; fi
  want=$(node "$ROOT/client/fnv.mjs" "$src")
  have=$(head -c 40 "$min" | sed -n "s|^/\\* $name \\([0-9a-f]*\\) \\*/.*|\\1|p")
  if [ "$want" = "$have" ]; then ok; else bad "client/$name.min.js is stale (banner '$have', $name.js hashes to $want): run client/build.sh"; fi
done

echo "$CEILINGS" | while read -r name max; do
  min="$ROOT/client/$name.min.js"
  [ -f "$min" ] || continue
  size=$(wc -c < "$min" | tr -d ' ')
  if [ "$size" -le "$max" ]; then echo "ok   $name.min.js $size / $max bytes"; else echo "FAIL $name.min.js $size > $max bytes"; fi
done > "${TMPDIR:-/tmp}/gw-runtime-sizes.$$"
cat "${TMPDIR:-/tmp}/gw-runtime-sizes.$$"
nfail=$(grep -c '^FAIL' "${TMPDIR:-/tmp}/gw-runtime-sizes.$$")
nok=$(grep -c '^ok' "${TMPDIR:-/tmp}/gw-runtime-sizes.$$")
rm -f "${TMPDIR:-/tmp}/gw-runtime-sizes.$$"
pass=$((pass + nok))
fail=$((fail + nfail))

if sh "$HERE/morph.sh"; then ok; else bad "test/morph.sh"; fi
if sh "$HERE/reactive.sh"; then ok; else bad "test/reactive.sh"; fi

echo "runtime: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
