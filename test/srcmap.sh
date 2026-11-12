#!/bin/sh
# goose-web's source-map suite (DESIGN-ADDENDUM-18, D1).
#
#   test/srcmap.sh
#
# gweb gen on test/srcmap must write .gooseweb/srcmap.txt equal to
# test/srcmap/expected.txt, which is worked out by hand from the D1 rules.
# Only gen runs, so no Goose compiler is needed beside gweb itself.
#
# Needs gweb built beside this folder (goose build -o gweb cli/gweb.goose).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-srcmap.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

cp -R "$HERE/srcmap" "$WORK/site"
rm -f "$WORK/site/expected.txt"
if out=$("$GWEB" -C "$WORK/site" gen 2>&1); then
  if [ ! -f "$WORK/site/.gooseweb/srcmap.txt" ]; then
    bad "gweb gen wrote no .gooseweb/srcmap.txt"
  elif diff_out=$(diff "$HERE/srcmap/expected.txt" "$WORK/site/.gooseweb/srcmap.txt"); then
    ok
  else
    bad "srcmap.txt differs from expected.txt (< expected, > got)"
    echo "$diff_out"
  fi
else
  bad "gweb gen"
  echo "$out"
fi

echo "srcmap: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
