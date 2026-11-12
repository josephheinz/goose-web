#!/bin/sh
# goose-web's page-template suite (DESIGN-ADDENDUM-6, section 8).
#
#   GOOSE=/path/to/goose test/templates.sh
#
# 1. test/templates/site is built, started on PORT, and GET / must equal
#    test/templates/expect.html byte for byte.
# 2. Every error of DESIGN-ADDENDUM-6 section 7, each in a copy of the site,
#    must fail gweb build with its message at its line.
#
# Needs curl, and gweb built beside this folder (goose build -o gweb cli/gweb.goose).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
PORT=${PORT:-3995}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-templates.XXXXXX")
PID=""
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# 1. The page renders as expected.
cp -R "$HERE/templates/site" "$WORK/ok"
if out=$("$GWEB" -C "$WORK/ok" build 2>&1); then
  "$WORK/ok/.gooseweb/server" --port "$PORT" >/dev/null 2>&1 &
  PID=$!
  got=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    if curl -s -o "$WORK/got.html" "http://127.0.0.1:$PORT/"; then got=yes; break; fi
  done
  kill "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null
  PID=""
  if [ -z "$got" ]; then bad "the server did not answer on port $PORT"
  elif cmp -s "$WORK/got.html" "$HERE/templates/expect.html"; then ok
  else bad "GET / differs from expect.html:"; diff "$HERE/templates/expect.html" "$WORK/got.html" | sed 's/^/    /'; fi
else
  bad "gweb build of the site"; echo "$out"
fi

# 2. Expected failures. The page is <p>x</p>, the case on line 2, <p>y</p>.
cp -R "$HERE/templates/site" "$WORK/f"
rm -rf "$WORK/f/.gooseweb"
PAGE='<p>x</p>
%s
<p>y</p>
'
LAYOUT='<!doctype html>
%s
<body>@slot()</body>
'

# expect_fail FILE TEXT LINE MESSAGE: FILE (app/page.html, app/layout.html or a
# component) holds TEXT, and the build must say FILE:LINE: error: MESSAGE.
expect_fail() {
  file=$1; text=$2; line=$3; msg=$4
  cp "$HERE/templates/site/app/page.html" "$WORK/f/app/page.html"
  cp "$HERE/templates/site/app/layout.html" "$WORK/f/app/layout.html"
  rm -f "$WORK/f/components/C.gshtml"
  case "$file" in
    app/page.html) printf "$PAGE" "$text" > "$WORK/f/$file" ;;
    app/layout.html) printf "$LAYOUT" "$text" > "$WORK/f/$file" ;;
    bare:*) file=${file#bare:}; printf '%s\n' "$text" > "$WORK/f/$file" ;;
    *) printf '<script goose>\nstruct State { n: i64 }\nfn f(s: State&) { s.n += 1; }\n</script>\n%s\n' "$text" > "$WORK/f/$file" ;;
  esac
  want="$file:$line: error: $msg"
  [ "$line" = 0 ] && want="$file: error: $msg"  # a whole-file error has no line
  if out=$("$GWEB" -C "$WORK/f" build 2>&1); then
    bad "'$text': gweb build succeeded"
  else
    case "$out" in
      *"$want"*) ok ;;
      *) bad "'$text': wanted '$want', got:"; echo "$out" | sed 's/^/    /' ;;
    esac
  fi
}

P=app/page.html
expect_fail $P '{{ x }}' 2 "'{{ e }}' is the old syntax: write {e} (escaped) or {#raw e} (not escaped)"
expect_fail $P '{{{ x }}}' 2 "'{{{ e }}}' is the old syntax: write {#raw e}"
expect_fail $P '{{> f(1)}}' 2 "'{{> f(a)}}' is the old syntax: write @f(a)"
expect_fail $P '{{component N(e)}}' 2 "'{{component Name(e)}}' is the old syntax: write @Name(e)"
expect_fail $P '{{slot}}' 2 "'{{slot}}' is the old syntax: write @slot()"
expect_fail $P '{{#if e}}' 2 "'{{#tag}}' is the old syntax: write it with one brace, as in {#if e} and {/if}"
expect_fail $P '{{/if}}' 2 "'{{#tag}}' is the old syntax: write it with one brace, as in {#if e} and {/if}"
expect_fail $P '{{-- x --}}' 2 "'{{-- --}}' is the old syntax: write {-- note --}"
expect_fail $P 'a } b' 2 "'}' without '{'; for a literal brace write &#125;"
expect_fail $P '{ctx.worker' 2 "{ needs } on the same line; for a literal brace write &#123;"
expect_fail $P '{}' 2 "empty { }"
expect_fail $P '{#when x}' 2 "unknown tag {#when x}"
expect_fail $P '{#else if }' 2 "{#else if e} needs an expression"
expect_fail $P '{#for}' 2 "{#for x in e} or {#for x, i in e}"
expect_fail $P '{#let}' 2 "{#let n = e} needs a name and a value"
expect_fail $P '{-- x' 2 "{-- needs --} on the same line"
expect_fail $P '{#if true}' 2 "{#if} is never closed with {/if}"
expect_fail $P '{#for i in 3}' 2 "{#for} is never closed with {/for}"
expect_fail $P '{/for}' 2 "{/for} does not close an open {#for}"
expect_fail $P '{/if}' 2 "{/if} does not close an open {#if}"
expect_fail $P '{#else}' 2 "{#else} outside {#if}"
expect_fail $P '{#else if true}' 2 "{#else if} outside {#if}"
expect_fail $P '@Nope(1)' 2 "no component named Nope (there is no components/Nope.gshtml); for a literal @ write &#64;"
expect_fail $P '@f(1' 2 "@name( needs its ) on the same line; for a literal @ write &#64;"
expect_fail $P '@slot()' 2 "@slot() is for layout.html only"
expect_fail app/layout.html '@slot(1)' 2 "@slot() takes no arguments"
expect_fail bare:app/layout.html '<main>x</main>' 0 "a layout needs @slot() where the page goes"
expect_fail components/C.gshtml '@C(s)' 5 "'@C()' is not available in client code (components v1)"
# Reactive components (Addendum 12 section 3.1): named props.
expect_fail $P '@RCounter(stat: 1, label: "x")' 2 "RCounter has no prop stat"
expect_fail $P '@RCounter(label: "x")' 2 "@RCounter needs prop start"
expect_fail $P '@RCounter(start: 1, label: "x", start: 2)' 2 "@RCounter passes prop start twice"
expect_fail $P '@RCounter(3, "x")' 2 "@RCounter takes named props: @RCounter(start: 3)"
# Section 5: an empty tag word, an element that never closes.
expect_fail $P '{#raw }' 2 "{#raw e} needs an expression"
expect_fail $P '<script>var a = 1;' 2 "<script> is never closed with </script>"
expect_fail $P '<style>p { color: red; }' 2 "<style> is never closed with </style>"
# A Goose error inside a tag reports the template's own line.
expect_fail $P '{ctx.nope}' 2 "struct Ctx has no field nope"

echo "templates.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
