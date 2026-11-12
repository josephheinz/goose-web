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
  # A component's hash depends on bytes only a build knows, so the page is compared with it replaced by HASH.
  sed -E 's|(/_gw/Brace)\.[0-9a-f]{8}\.js|\1.HASH.js|' "$WORK/got.html" > "$WORK/got.norm.html"
  if [ -z "$got" ]; then bad "the server did not answer on port $PORT"
  elif cmp -s "$WORK/got.norm.html" "$HERE/templates/expect.html"; then ok
  else bad "GET / differs from expect.html:"; diff "$HERE/templates/expect.html" "$WORK/got.norm.html" | sed 's/^/    /'; fi
  if [ -n "$got" ]; then
    # @asset wrote /site.<hash>.css; the hash is the first 8 digits of the file's FNV-1a 64.
    h=$(node "$ROOT/client/fnv.mjs" "$HERE/templates/site/public/site.css" | cut -c1-8)
    curl -s -D "$WORK/hashed.h" -o "$WORK/hashed.b" "http://127.0.0.1:$PORT/site.$h.css"
    curl -s -D "$WORK/plain.h" -o "$WORK/plain.b" "http://127.0.0.1:$PORT/site.css"
    if grep -qi '^cache-control: public, max-age=31536000, immutable' "$WORK/hashed.h"; then ok; else bad "the hashed URL lacks the immutable Cache-Control"; fi
    if grep -qi '^cache-control: public, max-age=0, must-revalidate' "$WORK/plain.h"; then ok; else bad "the plain URL lost must-revalidate"; fi
    if cmp -s "$WORK/hashed.b" "$WORK/plain.b" && cmp -s "$WORK/hashed.b" "$HERE/templates/site/public/site.css"; then ok; else bad "the hashed and plain URLs serve different bytes"; fi
    if [ "$(grep -ci '^etag:' "$WORK/hashed.h")" = 1 ] && [ "$(grep -i '^etag:' "$WORK/hashed.h")" = "$(grep -i '^etag:' "$WORK/plain.h")" ]; then ok; else bad "the hashed and plain URLs have different ETags"; fi
    # The minifier ran on loose.css, and the already-minified site.css came through unchanged (checked above).
    curl -s -o "$WORK/loose.b" "http://127.0.0.1:$PORT/loose.css"
    if cmp -s "$WORK/loose.b" "$HERE/templates/loose.min.css"; then ok; else bad "public/loose.css was not served minified"; fi
    # The gzip variant: site.css is over 1 KB, so it has one.
    U="http://127.0.0.1:$PORT/site.css"
    curl -s -H 'Accept-Encoding: gzip' -D "$WORK/gz.h" -o "$WORK/gz.b" "$U"
    if grep -qi '^content-encoding: gzip' "$WORK/gz.h" && grep -qi '^vary: .*accept-encoding' "$WORK/gz.h"; then ok; else bad "Accept-Encoding: gzip did not give Content-Encoding and Vary"; fi
    if gzip -dc "$WORK/gz.b" 2>/dev/null | cmp -s - "$WORK/plain.b"; then ok; else bad "the gzip body does not inflate to the plain body"; fi
    curl -s -H 'Accept-Encoding: gzip;q=0' -D "$WORK/q0.h" -o "$WORK/q0.b" "$U"
    if ! grep -qi '^content-encoding:' "$WORK/q0.h" && grep -qi '^vary: .*accept-encoding' "$WORK/q0.h" && cmp -s "$WORK/q0.b" "$WORK/plain.b"; then ok; else bad "gzip;q=0 did not give the plain body with Vary"; fi
    curl -s --compressed -o "$WORK/cz.b" "$U"
    if cmp -s "$WORK/cz.b" "$WORK/plain.b"; then ok; else bad "curl --compressed body differs from the plain body"; fi
    pe=$(grep -i '^etag:' "$WORK/plain.h" | cut -d' ' -f2 | tr -d '\r')
    ge=$(grep -i '^etag:' "$WORK/gz.h" | cut -d' ' -f2 | tr -d '\r')
    if [ "$ge" = "$(printf '%s' "$pe" | sed 's/"$/-gz"/')" ]; then ok; else bad "gzip ETag '$ge' is not the plain ETag '$pe' with -gz"; fi
    c1=$(curl -s -o /dev/null -w '%{http_code}' -H "If-None-Match: $pe" "$U")
    c2=$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept-Encoding: gzip' -H "If-None-Match: $ge" "$U")
    c3=$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept-Encoding: gzip' -H "If-None-Match: $pe" "$U")
    c4=$(curl -s -o /dev/null -w '%{http_code}' -H "If-None-Match: $ge" "$U")
    if [ "$c1 $c2 $c3 $c4" = "304 304 200 200" ]; then ok; else bad "If-None-Match statuses are '$c1 $c2 $c3 $c4', wanted '304 304 200 200'"; fi
    # The component's own URL: its hash is that of the JS it serves.
    cu=$(grep -o '/_gw/Brace\.[0-9a-f]\{8\}\.js' "$WORK/got.html" | head -1)
    curl -s -D "$WORK/cjs.h" -o "$WORK/cjs.b" "http://127.0.0.1:$PORT$cu"
    curl -s -o "$WORK/cjs0.b" "http://127.0.0.1:$PORT/_gw/Brace.js"
    ch=$(node "$ROOT/client/fnv.mjs" "$WORK/cjs.b" | cut -c1-8)
    if [ "$cu" = "/_gw/Brace.$ch.js" ] && grep -qi '^cache-control: .*immutable' "$WORK/cjs.h" && cmp -s "$WORK/cjs.b" "$WORK/cjs0.b"; then ok; else bad "component URL $cu: wrong hash, no immutable, or differs from /_gw/Brace.js"; fi
    # It imports the runtime by its hashed name, and that name exists.
    rt=$(grep -o 'gwi\.[0-9a-f]\{8\}\.js' "$WORK/cjs.b" | head -1)
    curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/_gw/$rt" > "$WORK/rt.status"
    if [ -n "$rt" ] && [ "$(cat "$WORK/rt.status")" = 200 ]; then ok; else bad "Brace.js imports '$rt', which is not served"; fi
  fi
  kill "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null
  PID=""
else
  bad "gweb build of the site"; echo "$out"
fi

# CSS minifier cases, and --no-minify.
if "$GWEB" test-css >"$WORK/css.out" 2>&1; then ok; else bad "gweb test-css:"; sed 's/^/    /' "$WORK/css.out"; fi
cp -R "$HERE/templates/site" "$WORK/nm"
rm -rf "$WORK/nm/.gooseweb"
"$GWEB" -C "$WORK/nm" gen --no-minify >/dev/null 2>&1
if [ -d "$WORK/nm/.gooseweb" ] && [ -z "$(ls "$WORK/nm/.gooseweb/_pub" 2>/dev/null)" ] && [ -n "$(ls "$WORK/ok/.gooseweb/_pub" 2>/dev/null)" ]; then ok; else bad "--no-minify did not skip the minified copies, or the default did not write them"; fi

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
# Section 5: an empty tag word, an element that never closes.
expect_fail $P '{#raw }' 2 "{#raw e} needs an expression"
expect_fail $P '<script>var a = 1;' 2 "<script> is never closed with </script>"
expect_fail $P '<style>p { color: red; }' 2 "<style> is never closed with </style>"
# @asset.
expect_fail $P '@asset()' 2 '@asset() takes one string literal, as in @asset("/css/site.css")'
expect_fail $P '@asset(x)' 2 '@asset() takes one string literal, as in @asset("/css/site.css")'
expect_fail $P '@asset("/nope.css")' 2 "no public file at /nope.css (looked for public/nope.css)"
expect_fail app/layout.html '@asset("/css/none.css")' 2 "no public file at /css/none.css (looked for public/css/none.css)"
# A hashed URL may not be another file's URL.
cp "$HERE/templates/site/app/page.html" "$WORK/f/app/page.html"
cp "$HERE/templates/site/app/layout.html" "$WORK/f/app/layout.html"
rm -f "$WORK/f/components/C.gshtml"
h=$(node "$ROOT/client/fnv.mjs" "$HERE/templates/site/public/site.css" | cut -c1-8)
printf 'x\n' > "$WORK/f/public/site.$h.css"
want="public/site.css: error: this file's hashed URL /site.$h.css is taken by /site.$h.css"
if out=$("$GWEB" -C "$WORK/f" build 2>&1); then bad "a file at the hashed URL: gweb build succeeded"
else case "$out" in *"$want"*) ok ;; *) bad "wanted '$want', got:"; echo "$out" | sed 's/^/    /' ;; esac; fi
rm -f "$WORK/f/public/site.$h.css"

# A Goose error inside a tag reports the template's own line.
expect_fail $P '{ctx.nope}' 2 "struct Ctx has no field nope"

echo "templates.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
