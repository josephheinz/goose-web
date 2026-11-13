#!/bin/sh
# gweb's sitemap suite (DESIGN-ADDENDUM-15, section 4).
#
#   GOOSE=/path/to/goose test/sitemap.sh
#
# 1. test/sitemap/site is built and started with SITE_URL set, then unset; curl checks /sitemap.xml and /robots.txt.
# 2. A copy with public/robots.txt must serve that file instead of the generated one.
# 3. Each build error, in a copy of the site, must fail gweb build with its message at its path.
# 4. gweb routes lists the generated routes.
#
# Needs curl, and gweb built beside this folder (goose build -o gweb cli/gweb.goose).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
PORT=${PORT:-3993}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-sitemap.XXXXXX")
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
  curl -s -X "$method" -D "$WORK/$name.h.raw" -o "$WORK/$name.b" -w '%{http_code}' "$@" "$URL$path" > "$WORK/$name.status"
  tr -d '\r' < "$WORK/$name.h.raw" | tr 'A-Z' 'a-z' > "$WORK/$name.h"
}
status() { cat "$WORK/$1.status"; }
has_header() { grep -q "^$2" "$WORK/$1.h"; }

# start DIR [VAR=VALUE...]: runs the built server with only those variables set from the suite's choice; SITE_URL is cleared first.
start() {
  dir=$1; shift
  env -u SITE_URL "$@" "$dir/.gooseweb/server" --port "$PORT" >/dev/null 2>&1 &
  PID=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    if curl -s -o /dev/null "$URL/"; then return 0; fi
  done
  return 1
}
stop() {
  kill "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null
  PID=""
}

# sitemap_for BASE: the expected /sitemap.xml. The literal pages are / and /about; /secret opts out and /post/[id] is dynamic.
sitemap_for() {
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' \
    "<url><loc>$1/</loc></url>" \
    "<url><loc>$1/about</loc></url>" \
    "<url><loc>$1/post/1?x=1&amp;y=2</loc><lastmod>2026-01-15</lastmod></url>" \
    '</urlset>'
}
robots_for() { printf 'User-agent: *\nAllow: /\nSitemap: %s/sitemap.xml\n' "$1"; }

# serves NAME PATH CTYPE WANT_FILE: GET PATH is 200 with the content type, the one-hour Cache-Control and WANT_FILE's bytes.
serves() {
  name=$1; path=$2; ctype=$3; file=$4; shift 4
  req "$name" GET "$path" "$@"
  check "$([ "$(status "$name")" = 200 ] && has_header "$name" "content-type: $ctype" && has_header "$name" 'cache-control: public, max-age=3600' \
    && cmp -s "$WORK/$name.b" "$file" && echo ok)" "GET $path: 200, $ctype, max-age=3600 and the expected body"
}

# 1. The site.
cp -R "$HERE/sitemap/site" "$WORK/ok"
if out=$("$GWEB" -C "$WORK/ok" build 2>&1); then
  if ! start "$WORK/ok" SITE_URL=https://example.com/; then
    bad "the server did not answer on port $PORT"
  else
    sitemap_for https://example.com > "$WORK/want.xml"
    serves sm /sitemap.xml 'application/xml' "$WORK/want.xml"
    robots_for https://example.com > "$WORK/want.txt"
    serves rb /robots.txt 'text/plain' "$WORK/want.txt"
    req smh HEAD /sitemap.xml
    check "$([ "$(status smh)" = 200 ] && has_header smh 'content-type: application/xml' && [ ! -s "$WORK/smh.b" ] && echo ok)" "HEAD /sitemap.xml: 200, no body"
    req smp POST /sitemap.xml
    check "$([ "$(status smp)" = 405 ] && has_header smp 'allow: get, head, options' && echo ok)" "POST /sitemap.xml: 405"
    req rbp POST /robots.txt
    check "$([ "$(status rbp)" = 405 ] && echo ok)" "POST /robots.txt: 405"
    req secret GET /secret
    check "$([ "$(status secret)" = 200 ] && echo ok)" "the page that opted out is still served"
    stop
  fi
  # Without SITE_URL the base is Host, and X-Forwarded-Proto picks the scheme.
  if ! start "$WORK/ok"; then
    bad "the server did not answer on port $PORT without SITE_URL"
  else
    sitemap_for "http://127.0.0.1:$PORT" > "$WORK/want.xml"
    serves smh2 /sitemap.xml 'application/xml' "$WORK/want.xml"
    robots_for "http://127.0.0.1:$PORT" > "$WORK/want.txt"
    serves rbh /robots.txt 'text/plain' "$WORK/want.txt"
    sitemap_for "https://shop.test" > "$WORK/want.xml"
    serves smx /sitemap.xml 'application/xml' "$WORK/want.xml" -H 'Host: shop.test' -H 'X-Forwarded-Proto: https'
    stop
  fi
else
  bad "gweb build of the site"; echo "$out"
fi

# 2. public/robots.txt wins.
rm -rf "$WORK/r"
cp -R "$HERE/sitemap/site" "$WORK/r"
mkdir -p "$WORK/r/public"
printf 'User-agent: *\nDisallow: /private\n' > "$WORK/r/public/robots.txt"
if out=$("$GWEB" -C "$WORK/r" build 2>&1); then
  if ! start "$WORK/r" SITE_URL=https://example.com; then
    bad "the server did not answer on port $PORT with public/robots.txt"
  else
    req rbs GET /robots.txt
    check "$([ "$(status rbs)" = 200 ] && cmp -s "$WORK/rbs.b" "$WORK/r/public/robots.txt" && has_header rbs 'etag: ' && echo ok)" "public/robots.txt is served as a static file"
    sitemap_for https://example.com > "$WORK/want.xml"
    serves sms /sitemap.xml 'application/xml' "$WORK/want.xml"
    stop
  fi
  routes=$("$GWEB" -C "$WORK/r" routes 2>&1)
  if echo "$routes" | grep -q 'route  GET,HEAD  *\/robots.txt'; then bad "gweb routes lists a generated /robots.txt beside public/robots.txt"; else ok; fi
else
  bad "gweb build with public/robots.txt"; echo "$out"
fi

# 2b. sitemap_base and fn robots (DESIGN-ADDENDUM-19, D10): the base and the robots text come from the request's host.
if out=$("$GWEB" -C "$HERE/sitemap/multi" build 2>&1); then
  if ! start "$HERE/sitemap/multi" SITE_URL=https://ignored.example; then
    bad "the multi-host server did not answer on port $PORT"
  else
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
      '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' \
      '<url><loc>https://a.test/</loc></url>' '<url><loc>https://a.test/p?a=1&amp;b=2</loc></url>' '</urlset>' > "$WORK/want.xml"
    serves mm /sitemap.xml 'application/xml' "$WORK/want.xml" -H 'Host: a.test'
    printf 'User-agent: *\nDisallow: /private\nSitemap: https://b.test/sitemap.xml\n' > "$WORK/want.txt"
    serves mr /robots.txt 'text/plain' "$WORK/want.txt" -H 'Host: b.test'
    stop
  fi
  rm -rf "$HERE/sitemap/multi/.gooseweb"
else
  bad "gweb build of the multi-host site"; echo "$out"
fi

# 3. Expected failures. expect_fail MESSAGE PATH SETUP: SETUP runs in a copy of the site, and the build must say PATH: error: MESSAGE.
expect_fail() {
  msg=$1; where=$2; setup=$3
  rm -rf "$WORK/f"
  cp -R "$HERE/sitemap/site" "$WORK/f"
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

expect_fail "public/sitemap.xml exists; remove it, or remove app/sitemap.goose, which generates /sitemap.xml" app/sitemap.goose \
  'mkdir public && echo x > public/sitemap.xml'
expect_fail "/sitemap.xml is generated by app/sitemap.goose; remove this folder" app/sitemap.xml \
  'mkdir app/sitemap.xml && echo "<p>x</p>" > app/sitemap.xml/page.html'
expect_fail "/robots.txt is generated by app/sitemap.goose; remove this folder or add public/robots.txt" app/robots.txt \
  'mkdir app/robots.txt && printf "import net.http;\nimport gweb;\nfn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {}\n" > app/robots.txt/route.goose'
expect_fail "write const SITEMAP = false; to leave this page out of /sitemap.xml (or const SITEMAP = true;)" app/secret/page.goose:1 \
  'echo "const SITEMAP = nope;" > app/secret/page.goose'
expect_fail "sitemap.goose belongs in app/ only" app/about/sitemap.goose 'echo "" > app/about/sitemap.goose'

# 4. gweb routes.
routes=$("$GWEB" -C "$HERE/sitemap/site" routes 2>&1)
for want in "route  GET,HEAD  *  /sitemap.xml  *app/sitemap.goose" "route  GET,HEAD  *  /robots.txt  *app/sitemap.goose"; do
  if echo "$routes" | grep -q "$want"; then ok; else bad "gweb routes lacks '$want':"; echo "$routes" | sed 's/^/    /'; fi
done

echo "sitemap.sh: $pass of $((pass + fail)) checks passed"
[ "$fail" -eq 0 ]
