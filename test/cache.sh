#!/bin/sh
# gweb's page cache and export suite (DESIGN-ADDENDUM-15, section 5).
#
#   GOOSE=/path/to/goose test/cache.sh
#
# 1. test/cache/site is built and started with one worker (the cache is per worker). /cached has REVALIDATE = 2 and shows
#    a counter from app/state.goose, so a cached reply repeats the number and a fresh render changes it.
# 2. Each build error, in a copy of the site, must fail gweb build with its message at its path.
# 3. gweb export writes the site's tree; a page that answers 404 makes it exit 1 after the rest is written.
#
# Needs curl, and gweb built beside this folder (goose build -o gweb cli/gweb.goose).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
PORT=${PORT:-3996}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-cache.XXXXXX")
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
  if [ "$method" = HEAD ]; then
    curl -s -I -D "$WORK/$name.h.raw" -o "$WORK/$name.b" -w '%{http_code}' "$@" "$URL$path" > "$WORK/$name.status"
  else
    curl -s -X "$method" -D "$WORK/$name.h.raw" -o "$WORK/$name.b" -w '%{http_code}' "$@" "$URL$path" > "$WORK/$name.status"
  fi
  tr -d '\r' < "$WORK/$name.h.raw" | tr 'A-Z' 'a-z' > "$WORK/$name.h"
}
status() { cat "$WORK/$1.status"; }
has_header() { grep -q "^$2" "$WORK/$1.h"; }
etag() { sed -n 's/^etag: //p' "$WORK/$1.h"; }
same() { cmp -s "$WORK/$1.b" "$WORK/$2.b"; }

# 1. The cache.
cp -R "$HERE/cache/site" "$WORK/ok"
if out=$("$GWEB" -C "$WORK/ok" build 2>&1); then
  "$WORK/ok/.gooseweb/server" --port "$PORT" --workers 1 >/dev/null 2>&1 &
  PID=$!
  up=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    if curl -s -o /dev/null "$URL/"; then up=1; break; fi
  done
  if [ -z "$up" ]; then
    bad "the server did not answer on port $PORT"
  else
    req a GET /cached
    req b GET /cached
    check "$([ "$(status a)" = 200 ] && same a b && grep -q '<main>' "$WORK/a.b" && grep -q 'n=1' "$WORK/a.b" && echo ok)" "two GETs of /cached: 200, the same full page"
    check "$(has_header a 'cache-control: public, max-age=0, must-revalidate' && [ -n "$(etag a)" ] && [ "$(etag a)" = "$(etag b)" ] && echo ok)" "the reply has Cache-Control and a stable ETag"
    TAG=$(etag a)
    req c GET /cached -H "If-None-Match: $TAG"
    check "$([ "$(status c)" = 304 ] && [ ! -s "$WORK/c.b" ] && [ "$(etag c)" = "$TAG" ] && echo ok)" "If-None-Match with the ETag: 304"
    req d GET /cached -H 'If-None-Match: "0000000000000000"'
    check "$([ "$(status d)" = 200 ] && same a d && echo ok)" "If-None-Match with another ETag: 200 and the cached body"
    req h HEAD /cached
    check "$([ "$(status h)" = 200 ] && [ "$(etag h)" = "$TAG" ] && echo ok)" "HEAD /cached: 200 and the ETag"
    req f GET /cached -H 'GW-Fragment: x'
    check "$([ "$(status f)" = 200 ] && ! same a f && ! has_header f 'etag: ' && echo ok)" "a request with GW-Fragment skips the cache"

    TK=0123456789abcdef0123456789abcdef
    req p POST /cached -H "Cookie: gw_csrf=$TK" -H "X-CSRF-Token: $TK" -d 'x=1'
    check "$([ "$(status p)" = 200 ] && ! same a p && ! has_header p 'etag: ' && ! has_header p 'cache-control: public' && echo ok)" "POST /cached: rendered fresh, no ETag"
    req g GET /cached
    check "$(same a g && echo ok)" "the POST did not replace the cached page"

    req k1 GET /cookie
    req k2 GET /cookie
    check "$([ "$(status k1)" = 200 ] && ! same k1 k2 && has_header k1 'set-cookie: seen=1' && has_header k2 'set-cookie: seen=1' \
      && ! has_header k1 'etag: ' && echo ok)" "/cookie sets a cookie: never cached, no ETag"

    sleep 3
    req e GET /cached
    check "$([ "$(status e)" = 200 ] && ! same a e && [ "$(etag e)" != "$TAG" ] && echo ok)" "after 3 s the page is rendered again"
    req e2 GET /cached
    check "$(same e e2 && echo ok)" "and the new page is cached"
    req nr GET /about
    check "$([ "$(status nr)" = 200 ] && ! has_header nr 'etag: ' && echo ok)" "a page without REVALIDATE gets no ETag"
  fi
  kill "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null
  PID=""
else
  bad "gweb build of the site"; echo "$out"
fi

# 2. Expected failures. expect_fail MESSAGE PATH SETUP: SETUP runs in a copy of the site, and the build must say PATH: error: MESSAGE.
expect_fail() {
  msg=$1; where=$2; setup=$3
  rm -rf "$WORK/f"
  cp -R "$HERE/cache/site" "$WORK/f"
  (cd "$WORK/f" && eval "$setup")
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

expect_fail "a page with REVALIDATE cannot use a CSRF token; its HTML would be shared by every visitor" app/form/page.goose \
  'mkdir app/form && echo "const REVALIDATE = 5;" > app/form/page.goose && echo "<form>@gweb::csrf_field(ctx)</form>" > app/form/page.html'
expect_fail "a page with REVALIDATE cannot use a CSRF token; its HTML would be shared by every visitor" app/about/page.goose \
  'echo "const REVALIDATE = 5;" > app/about/page.goose && echo "<form>@gweb::csrf_field(ctx)</form>" > app/layout.html'
expect_fail "write const REVALIDATE = N; with N the seconds to cache this page, a whole number above 0" app/about/page.goose:1 \
  'echo "const REVALIDATE = soon;" > app/about/page.goose'
expect_fail "write const REVALIDATE = N; with N the seconds to cache this page, a whole number above 0" app/about/page.goose:1 \
  'echo "const REVALIDATE = 0;" > app/about/page.goose'
expect_fail "write const REVALIDATE = N; with N the seconds to cache this page, a whole number above 0" app/about/page.goose:1 \
  'echo "const REVALIDATE = 5" > app/about/page.goose'

# 3. gweb export.
OUT="$WORK/out"
cp -R "$HERE/cache/site" "$WORK/x"
if out=$(cd "$WORK/x" && SITE_URL=https://example.com "$GWEB" export -o "$OUT" 2>&1); then
  last=$(echo "$out" | tail -n 1)
  check "$([ "$last" = "gweb: exported 6 pages and 4 files to $OUT" ] && echo ok)" "the last line counts 6 pages and 4 files, got: $last"
  check "$(echo "$out" | grep -q 'skipped /user/\[name\]' && echo ok)" "the dynamic page without static_paths is listed as skipped"
  for f in index.html about.html cached.html cookie.html post/1.html post/2.html sitemap.xml robots.txt site.css; do
    check "$([ -f "$OUT/$f" ] && echo ok)" "export wrote $f"
  done
  hashed=$(ls "$OUT" | grep '^site\.[0-9a-f]\{8\}\.css$' | head -n 1)
  check "$([ -n "$hashed" ] && cmp -s "$OUT/$hashed" "$OUT/site.css" && echo ok)" "the static file is at its plain and hashed names"
  check "$([ ! -e "$OUT/user" ] && [ ! -e "$OUT/post/[id].html" ] && echo ok)" "nothing is written for the skipped page"
  check "$(grep -q '<h1>home</h1>' "$OUT/index.html" && grep -q '<main>' "$OUT/index.html" && echo ok)" "index.html is the full home page"
  check "$(grep -q 'post 2' "$OUT/post/2.html" && echo ok)" "post/2.html is the page for /post/2"
  check "$(grep -q '<loc>https://example.com/about</loc>' "$OUT/sitemap.xml" && grep -q '<loc>https://example.com/post/1</loc>' "$OUT/sitemap.xml" && echo ok)" "sitemap.xml lists the pages with SITE_URL"
  check "$(grep -q 'Sitemap: https://example.com/sitemap.xml' "$OUT/robots.txt" && echo ok)" "robots.txt names the sitemap"
else
  bad "gweb export"; echo "$out"
fi

# A page that answers 404 is an error, but the rest is still written.
rm -rf "$WORK/y" "$WORK/out2"
cp -R "$HERE/cache/site" "$WORK/y"
mkdir "$WORK/y/app/gone"
printf 'import std;\nimport net.http;\nimport gweb;\nstruct Props { n: i64 }\nfn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {\n    gweb::not_found(ctx);\n    return Props { n: 0 };\n}\n' > "$WORK/y/app/gone/page.goose"
echo '<p>gone</p>' > "$WORK/y/app/gone/page.html"
out=$(cd "$WORK/y" && "$GWEB" export -o "$WORK/out2" 2>&1)
code=$?
check "$([ "$code" = 1 ] && echo "$out" | grep -q '/gone: the reply is 404' && [ -f "$WORK/out2/about.html" ] && [ ! -f "$WORK/out2/gone.html" ] && echo ok)" "a 404 page: exit 1, the error named, the other pages written"

echo "cache.sh: $pass of $((pass + fail)) checks passed"
[ "$fail" -eq 0 ]
