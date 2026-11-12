#!/bin/sh
# goose-web's catch-all suite (DESIGN-ADDENDUM-8, section 10).
#
#   GOOSE=/path/to/goose test/catchall.sh
#
# 1. test/catchall/site is built and started; curl checks precedence, tails, refusals and statics.
# 2. Each build error, in a copy of the site, must fail gweb build with its message at its path.
# 3. gweb routes lists the catch-alls.
#
# Needs curl and python3, and gweb built beside this folder (goose build -o gweb cli/gweb.goose).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
PORT=${PORT:-3994}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-catchall.XXXXXX")
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
check() { if [ "$1" = ok ]; then ok; else bad "$2"; fi; }

URL="http://127.0.0.1:$PORT"
# req NAME METHOD PATH [curl args]: status in $WORK/NAME.status, headers in NAME.h (lower case), body in NAME.b.
req() {
  name=$1; method=$2; path=$3; shift 3
  curl -s --path-as-is -X "$method" -D "$WORK/$name.h.raw" -o "$WORK/$name.b" -w '%{http_code}' "$@" "$URL$path" > "$WORK/$name.status"
  tr -d '\r' < "$WORK/$name.h.raw" | tr 'A-Z' 'a-z' > "$WORK/$name.h"
}
status() { cat "$WORK/$1.status"; }
has_header() { grep -q "^$2" "$WORK/$1.h"; }
body() { cat "$WORK/$1.b"; }
# says NAME PATH WANT: GET PATH is 200 and its body, ignoring the trailing newline, starts with WANT.
says() {
  req "$1" GET "$2"
  got=$(head -n 1 "$WORK/$1.b")
  check "$([ "$(status "$1")" = 200 ] && [ "$got" = "$3" ] && echo ok)" "GET $2: 200 and '$3', got $(status "$1") '$got'"
}
refused() {
  req "$1" GET "$2"
  check "$([ "$(status "$1")" = 404 ] && grep -q 'not-found-page' "$WORK/$1.b" && echo ok)" "GET $2: 404 and the not-found page, got $(status "$1")"
}
repeat() { python3 -I -c 'import sys; sys.stdout.write(sys.argv[1] * int(sys.argv[2]))' "$1" "$2"; }

# 1. The site.
cp -R "$HERE/catchall/site" "$WORK/ok"
if out=$("$GWEB" -C "$WORK/ok" build --no-minify 2>&1); then
  "$WORK/ok/.gooseweb/server" --port "$PORT" >/dev/null 2>&1 &
  PID=$!
  up=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    if curl -s -o /dev/null "$URL/"; then up=yes; break; fi
  done
  if [ -z "$up" ]; then
    bad "the server did not answer on port $PORT"
  else
    req home GET /
    check "$([ "$(status home)" = 200 ] && grep -q 'home' "$WORK/home.b" && echo ok)" "GET /: 200 home"
    says d0 /docs 'docs:[]'
    says d1 /docs/a 'docs:[a]'
    says d3 /docs/a/b/c 'docs:[a/b/c]'
    says dc /docs/caf%C3%A9 'docs:[caf%C3%A9]'
    for p in /docs/a//b /docs/a/../b /docs/a/./b /docs/%2e%2e/x /docs/a%2Fb /docs/a%5Cb /docs/a%00b /docs/%zz; do refused bad "$p"; done
    req slash GET /docs/a/
    check "$([ "$(status slash)" = 308 ] && has_header slash 'location: /docs/a$' && echo ok)" "GET /docs/a/: 308 to /docs/a"
    req pslash POST /docs/a/
    check "$([ "$(status pslash)" = 404 ] && echo ok)" "POST /docs/a/: 404 (empty last segment)"
    req pslash0 POST /docs/
    check "$([ "$(status pslash0)" = 404 ] && echo ok)" "POST /docs/: 404, not an empty tail"
    req frag GET /docs/a -H 'GW-Fragment: body'
    check "$([ "$(status frag)" = 200 ] && has_header frag 'gw-fragment: body' && [ "$(body frag)" = '<p>1</p>' ] && echo ok)" "a catch-all page's fragment"

    says a1 /blog 'all:blog'
    says a2 /shop 'all:shop'
    says a3 /shop/tools 'all:shop/tools'
    says a4 /x/y/z 'all:x/y/z'
    says b1 /blog/new 'blog-new'
    says b2 /blog/7 'blog-id:7'
    says b3 /blog/7/comments 'blog-rest:7/comments'
    says b4 /blog/new/x 'blog-rest:new/x'
    says s1 /shop/tools/a/b 'shop:tools:a/b'

    for f in /favicon.ico:public/favicon.ico /css/site.css:public/css/site.css /blog/logo.txt:public/blog/logo.txt; do
      u=${f%%:*}; file=${f#*:}
      req st GET "$u"
      check "$([ "$(status st)" = 200 ] && cmp -s "$WORK/st.b" "$HERE/catchall/site/$file" && has_header st 'etag: ' && echo ok)" "GET $u: the file bytes and an ETag"
    done
    req pf POST /favicon.ico
    check "$([ "$(status pf)" = 200 ] && [ "$(head -n 1 "$WORK/pf.b")" = 'all:favicon.ico' ] && echo ok)" "POST /favicon.ico reaches the catch-all"
    req pl POST /blog/logo.txt
    check "$([ "$(status pl)" = 405 ] && echo ok)" "POST /blog/logo.txt reaches blog/[id], which has only GET"
    head=$(python3 -I - "$PORT" <<'PY'
import http.client, sys
c = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]))
c.request("HEAD", "/blog/7")
r = c.getresponse()
print(r.status, len(r.read()))
PY
)
    check "$([ "$head" = '200 0' ] && echo ok)" "HEAD /blog/7: 200, empty body, got '$head'"

    for n in 17 40; do
      p=$(repeat /a "$n")
      want=$(repeat a/ "$n"); want="all:${want%/}"
      says "deep$n" "$p" "$want"
    done
    long=$(repeat x 300)
    req cap GET "/blog/$long"
    check "$([ "$(status cap)" = 404 ] && echo ok)" "/blog/ and 300 bytes: 404 from blog/[id], no fallthrough"
    t1024=$(repeat x 1024)
    t1025=$(repeat x 1025)
    req t1 GET "/docs/$t1024"
    check "$([ "$(status t1)" = 200 ] && echo ok)" "a 1024-byte tail: 200"
    req t2 GET "/docs/$t1025"
    check "$([ "$(status t2)" = 404 ] && echo ok)" "a 1025-byte tail: 404"
  fi
  kill "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null
  PID=""
else
  bad "gweb build of the site"; echo "$out"
fi

# 2. Expected failures. expect_fail MESSAGE PATH FILE...: FILE is created, and the build must say PATH: error: MESSAGE.
expect_fail() {
  msg=$1; where=$2; shift 2
  rm -rf "$WORK/f"
  cp -R "$HERE/catchall/site" "$WORK/f"
  for file in "$@"; do
    mkdir -p "$WORK/f/$(dirname "$file")"
    cp "$HERE/catchall/site/app/blog/new/route.goose" "$WORK/f/$file" 2>/dev/null || echo x > "$WORK/f/$file"
  done
  want="$where: error: $msg"
  if out=$("$GWEB" -C "$WORK/f" build 2>&1); then
    bad "'$where': gweb build succeeded"
  else
    case "$out" in
      *"$want"*) ok ;;
      *) bad "wanted '$want', got:"; echo "$out" | sed 's/^/    /' ;;
    esac
  fi
}

expect_fail "a catch-all folder is the last segment of its route; move this folder out of it" \
  'app/docs/[[...path]]/more' 'app/docs/[[...path]]/more/page.html'
expect_fail "a folder holds one catch-all folder at most" 'app/blog/[...x]' 'app/blog/[...x]/route.goose'
expect_fail 'app/docs/[[...path]] and app/docs both answer /docs; use [...path] or remove one' \
  'app/docs/[[...path]]' app/docs/page.html
expect_fail "the catch-all name id is already a parameter of this path" 'app/u/[id]/[...id]' 'app/u/[id]/[...id]/route.goose'
for dir in '[..x]' '[...9x]' '[[...x]' '[[x]]'; do
  expect_fail "a dynamic segment folder is [name], [...name] or [[...name]], where name is an identifier" \
    "app/$dir" "app/$dir/page.html"
done
expect_fail "a route is at most 16 folders deep" app/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q app/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/page.html

rm -rf "$WORK/f"
cp -R "$HERE/catchall/site" "$WORK/f"
echo '<a href="/docs/a" gw-target="nope">x</a>' >> "$WORK/f/app/page.html"
want='app/page.html:4: error: gw-target: app/docs/[[...path]]/page.html has no {#fragment nope}'
if out=$("$GWEB" -C "$WORK/f" build 2>&1); then bad "gw-target nope: gweb build succeeded"
else case "$out" in *"$want"*) ok ;; *) bad "wanted '$want', got:"; echo "$out" | sed 's/^/    /' ;; esac; fi

# 3. gweb routes.
routes=$("$GWEB" -C "$HERE/catchall/site" routes 2>&1)
for want in "/docs/[[...path]]" "route  GET,POST             /[...all]" "frag   body"; do
  case "$routes" in *"$want"*) ok ;; *) bad "gweb routes lacks '$want':"; echo "$routes" | sed 's/^/    /' ;; esac
done

echo "catchall.sh: $pass of $((pass + fail)) checks passed"
[ "$fail" -eq 0 ]
