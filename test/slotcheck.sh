#!/bin/sh
# @slot() inside <title>, <textarea>, <script> or <style> of a layout or view is a build error at its line (1.1).
#
#   test/slotcheck.sh
#
# Needs gweb built beside this folder (goose build -o gweb cli/gweb.goose). Starts no server and needs no compiler:
# gweb gen reports the errors.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-slotcheck.XXXXXX")
trap 'rm -rf "${WORK:?}"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
show() { echo "$1" | sed 's/^/    /'; }

# layout NAME HTML: a project whose layout.html is HTML.
layout() {
  mkdir -p "$WORK/$1/app"
  printf '%s\n' "$2" > "$WORK/$1/app/layout.html"
  printf '<h1>x</h1>\n' > "$WORK/$1/app/page.html"
}
expect_fail() {   # expect_fail NAME WANT
  if out=$("$GWEB" -C "$WORK/$1" gen 2>&1); then bad "$1: gweb gen succeeded"
  else case "$out" in *"$2"*) ok ;; *) bad "$1: wanted '$2', got:"; show "$out" ;; esac; fi
}
expect_ok() {
  if out=$("$GWEB" -C "$WORK/$1" gen 2>&1); then ok; else bad "$1: gweb gen failed"; show "$out"; fi
}

layout title '<html><head>
<title>Site @slot()</title>
</head><body>@slot()</body></html>'
expect_fail title 'app/layout.html:2: error: @slot() inside <title> would be written as text'

layout area '<html><body><form>
<textarea name="a">
@slot()
</textarea>
</form></body></html>'
expect_fail area 'app/layout.html:3: error: @slot() inside <textarea>'

layout script '<html><body>
<script>
var x = "@slot()";
</script>
@slot()</body></html>'
expect_fail script 'app/layout.html:3: error: @slot() inside <script>'

layout style '<html><head><STYLE>a { content: "@slot()"; }</STYLE></head><body>@slot()</body></html>'
expect_fail style 'app/layout.html:1: error: @slot() inside <style>'

# Fine: the slot is after the element is closed, or the element holds no slot.
layout fine '<html><head><title>Plain</title><style>a { color: red; }</style></head>
<body><textarea>x</textarea><script>var y = 1;</script>
@slot()</body></html>'
expect_ok fine

# A view template is checked too.
mkdir -p "$WORK/view/app" "$WORK/view/views/layouts"
printf '<h1>x</h1>\n' > "$WORK/view/app/page.html"
printf 'import std;\nstruct Props { a: u8[..10] = "" }\n' > "$WORK/view/views/layouts/Page.goose"
printf '<html><head><title>@slot("t")</title></head><body>@slot("body")</body></html>\n' > "$WORK/view/views/layouts/Page.html"
expect_fail view 'views/layouts/Page.html:1: error: @slot() inside <title>'

echo "slotcheck.sh: $pass of $((pass + fail)) checks passed"
[ "$fail" -eq 0 ]
