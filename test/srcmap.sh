#!/bin/sh
# gweb's source-map suite (DESIGN-ADDENDUM-18, D1).
#
#   test/srcmap.sh
#
# gweb gen on test/srcmap must write .gweb/srcmap.txt equal to
# test/srcmap/expected.txt, which is worked out by hand from the D1 rules.
# Only gen runs, so no Goose compiler is needed beside gweb itself.
#
# Step 3: lsp-gen --overlay reads the changed page from a temp file into .gweb.lsp/ and
# leaves .gweb/ alone; check and lsp-gen on a page.html with a type error (needs goose).
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
  if [ ! -f "$WORK/site/.gweb/srcmap.txt" ]; then
    bad "gweb gen wrote no .gweb/srcmap.txt"
  elif diff_out=$(diff "$HERE/srcmap/expected.txt" "$WORK/site/.gweb/srcmap.txt"); then
    ok
  else
    bad "srcmap.txt differs from expected.txt (< expected, > got)"
    echo "$diff_out"
  fi
else
  bad "gweb gen"
  echo "$out"
fi

# lsp-gen --overlay: the buffer text lands in .gweb.lsp/, and .gweb/ stays absent.
cp -R "$HERE/srcmap" "$WORK/lsp"
rm -f "$WORK/lsp/expected.txt"
printf '<h1>OVERLAY-MARK</h1>\n' > "$WORK/overlay.html"
if "$GWEB" -C "$WORK/lsp" lsp-gen --overlay app/page.html "$WORK/overlay.html" >/dev/null 2>&1; then
  if ! grep -rq OVERLAY-MARK "$WORK/lsp/.gweb.lsp"; then
    bad "lsp-gen --overlay: changed text missing from .gweb.lsp/"
  elif [ -e "$WORK/lsp/.gweb" ]; then
    bad "lsp-gen wrote .gweb/"
  elif [ ! -f "$WORK/lsp/.gweb.lsp/srcmap.txt" ]; then
    bad "lsp-gen wrote no srcmap.txt"
  else
    ok
  fi
else
  bad "lsp-gen --overlay exited nonzero"
fi

# A type error in page.html: check names its line and exits 1; lsp-gen --check exits 0.
if command -v "${GOOSE:-goose}" >/dev/null 2>&1; then
  cp -R "$HERE/srcmap" "$WORK/bad"
  rm -f "$WORK/bad/expected.txt"
  printf '<h1>Hi</h1>\n<p>{props.n + "x" * 2}</p>\n' > "$WORK/bad/app/page.html"
  rm -f "$WORK/bad/app/page.goose"
  out=$("$GWEB" -C "$WORK/bad" check 2>&1); status=$?
  if [ "$status" -ne 1 ]; then
    bad "check on a type error exited $status, wanted 1"
  elif ! echo "$out" | grep -q '^app/page\.html:[0-9][0-9]*: error:'; then
    bad "check printed no app/page.html:LINE: error:"
    echo "$out"
  elif [ -e "$WORK/bad/.gweb" ]; then
    bad "check wrote .gweb/"
  else
    ok
  fi
  out=$("$GWEB" -C "$WORK/bad" lsp-gen --check 2>&1); status=$?
  if [ "$status" -ne 0 ]; then bad "lsp-gen --check exited $status, wanted 0"; else ok; fi
else
  echo "skip: no goose compiler, check and lsp-gen --check not run"
fi

echo "srcmap: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
