#!/bin/sh
# gweb's CMS-readiness suite (DESIGN-ADDENDUM-20): a CMS package on gweb, end to end over HTTP.
#
#   GOOSE=/path/to/goose test/cmsready.sh
#
# test/cmsready/cms is a package with its own gweb.package, mounted at /admin: pages, a layout, a login guard
# (middleware), views (a page type, a section and a widget with @slot zones), a component and lib code with
# SQLite. It is installed from a git source: a bare repo made here, declared as file://...@v0.1.0 in gweb.packages.
# test/cmsready/site/admin/shop is a second, local package mounted inside it at /admin/shop.
# test/cmsready/site is the host app: a catch-all page that loads a node from SQLite and renders its page type and
# widgets by name through the views registry, a markdown widget, /media through gweb::send_file, two hosts (two
# channels) cached by host + path with epoch_bump(), a sitemap per host and gweb::reserved_prefixes().
#
# 1. Build the project; check the routes and the package clone.
# 2. Serve it (one worker, the cache is per worker) and walk the public site, the admin login, an edit through the
#    generated form, the cache epoch, media upload and download (200, 304, HEAD, a streamed file, hostile paths).
# 3. gweb test runs the package's views and components in the host project.
#
# Needs curl and git, and gweb built beside this folder (goose build -o gweb cli/gweb.goose).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
PORT=${PORT:-4005}
if [ ! -x "$GWEB" ]; then echo "cmsready.sh: $GWEB is missing; build it first: goose build -o gweb cli/gweb.goose" >&2; exit 2; fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-cmsready.XXXXXX")
PID=""
stop() {
  if [ -n "$PID" ]; then
    kill "$PID" 2>/dev/null
    wait "$PID" 2>/dev/null
    PID=""
  fi
}
cleanup() {
  stop
  rm -rf "$WORK"
}
trap cleanup EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { if [ "$1" = ok ]; then ok; else bad "$2"; fi; }
show() { echo "$1" | sed 's/^/    /'; }

# Not a fixture secret anywhere else: the session and CSRF cookies are signed with it.
export GWEB_SECRET=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff
export GWEB_PKG_CACHE="$WORK/pkgcache"

# 1. The package, as a git source.
TAG=v0.1.0
mkdir -p "$WORK/src"
cp -R "$HERE/cmsready/cms/." "$WORK/src/"
(
  cd "$WORK/src" || exit 1
  git init -q -b main
  git add -A
  git -c maintenance.auto=false -c gc.auto=0 -c user.name=cmsready -c user.email=cmsready@localhost commit -q -m "cms package"
  git tag "$TAG"
) || { bad "git: making the package repo"; exit 1; }
git clone -q --bare "$WORK/src" "$WORK/cms.git" || { bad "git: cloning the bare repo"; exit 1; }

cp -R "$HERE/cmsready/site" "$WORK/site"
printf '# the CMS package from git, and a module inside its mount\nfile://%s/cms.git@%s at /admin\n./admin/shop at /admin/shop\n' "$WORK" "$TAG" > "$WORK/site/gweb.packages"

routes=$("$GWEB" -C "$WORK/site" routes 2>&1)
for want in '/admin  ' '/admin/login' '/admin/nodes/[id]' '/admin/media' '/admin/shop  ' '/admin/shop/orders' '/media/[key]/[name]' '/[[...path]]'; do
  case "$routes" in *"$want"*) ok ;; *) bad "gweb routes lacks '$want':"; show "$routes" ;; esac
done
check "$([ -d "$GWEB_PKG_CACHE/url" ] && [ -f "$GWEB_PKG_CACHE"/url/*/gweb.package ] && echo ok)" "the package was cloned from its file:// source into the cache"

if ! out=$("$GWEB" -C "$WORK/site" build 2>&1); then
  bad "gweb build of the host project"; show "$out"
  echo "cmsready.sh: $pass of $((pass + fail)) checks passed"
  exit 1
fi
case "$out" in *warning*) bad "the build printed warnings:"; show "$out" ;; *) ok ;; esac

# 2. Serve.
JAR="$WORK/jar"
URL="http://admin.test:$PORT"
# curl resolves every fake host name to the server, so cookies and Host headers behave as on the real names.
RESOLVE="--resolve admin.test:$PORT:127.0.0.1 --resolve a.test:$PORT:127.0.0.1 --resolve b.test:$PORT:127.0.0.1 --resolve c.test:$PORT:127.0.0.1"
# req NAME METHOD HOST PATH [curl args]: status in NAME.status, headers lower-cased in NAME.h (raw in NAME.h.raw), body in NAME.b.
req() {
  name=$1; method=$2; host=$3; path=$4; shift 4
  if [ "$method" = HEAD ]; then
    : > "$WORK/$name.b"
    curl -s $RESOLVE -I -b "$JAR" -c "$JAR" -D "$WORK/$name.h.raw" -o /dev/null -w '%{http_code}' "$@" "http://$host:$PORT$path" > "$WORK/$name.status"
  else
    curl -s $RESOLVE -X "$method" -b "$JAR" -c "$JAR" -D "$WORK/$name.h.raw" -o "$WORK/$name.b" -w '%{http_code}' "$@" "http://$host:$PORT$path" > "$WORK/$name.status"
  fi
  tr -d '\r' < "$WORK/$name.h.raw" | tr 'A-Z' 'a-z' > "$WORK/$name.h"
}
status() { cat "$WORK/$1.status"; }
has_header() { grep -q "^$2" "$WORK/$1.h"; }
header() { sed -n "s/^$2: //p" "$WORK/$1.h" | head -n 1; }
body_has() { grep -qF -- "$2" "$WORK/$1.b"; }
loc() { tr -d '\r' < "$WORK/$1.h.raw" | sed -n 's/^[Ll]ocation: //p'; }
token() { sed -n 's/.*name="_csrf" value="\([^"]*\)".*/\1/p' "$WORK/$1.b" | head -n 1; }
refused() { [ "$(status "$1")" = 303 ] && case "$(loc "$1")" in "/admin?error="*) return 0 ;; esac; return 1; }
stamp() { sed -n 's/.*<!--stamp:\([0-9]*\)-->.*/\1/p' "$WORK/$1.b" | head -n 1; }

# Starts the server and polls up to 30 s. A zombie passes kill -0 under dash, so ps decides.
alive() { [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null && case "$(ps -o stat= -p "$PID" 2>/dev/null)" in ''|Z*) return 1 ;; esac; }
start() {
  (cd "$WORK/site" && exec ./.gooseweb/server --port "$PORT" --workers 1 >"$WORK/server.log" 2>&1) &
  PID=$!
  deadline=$(( $(date +%s) + 30 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    alive || return 1
    if curl -s -o /dev/null "http://127.0.0.1:$PORT/"; then return 0; fi
    sleep 0.2
  done
  return 1
}

if ! start; then
  bad "the server did not answer on port $PORT"; show "$(cat "$WORK/server.log" 2>/dev/null)"
  echo "cmsready.sh: $pass of $((pass + fail)) checks passed"
  exit 1
fi

# 2a. The public site: two hosts, two channels.
req a1 GET a.test /
check "$([ "$(status a1)" = 200 ] && body_has a1 'Home A' && body_has a1 'site-a' && body_has a1 'data-root-layout' && echo ok)" "a.test/: 200, channel A in the host's root layout"
check "$(body_has a1 'class="site site-a"' && body_has a1 '<strong>world</strong>' && body_has a1 '<blockquote>Quoted on A' && body_has a1 'class="two-col wide"' && echo ok)" "a.test/: the package's markdown widget and section, and the host's own widget, rendered by name from stored JSON"
req b1 GET b.test /
check "$([ "$(status b1)" = 200 ] && body_has b1 'Home B' && body_has b1 'class="plain plain-b"' && ! body_has b1 'Home A' && ! body_has b1 'site-' && echo ok)" "b.test/: channel B with its own layout view (from the package), not A"
req ab GET a.test /about
check "$([ "$(status ab)" = 200 ] && body_has ab 'About A' && body_has ab 'class="article dark"' && echo ok)" "a.test/about: 200 with the Dark theme"
check "$(body_has ab '<img src="/media/m1/up.txt" alt="Uploaded">' && body_has ab 'data-component="Pill"' && echo ok)" "a.test/about: a widget with a foreign field type from the package lib, and a component inside a view template"
req bb GET b.test /about
check "$([ "$(status bb)" = 404 ] && echo ok)" "b.test/about: 404, the node belongs to A"
req cc GET c.test /
check "$([ "$(status cc)" = 404 ] && echo ok)" "an unknown host: 404"
req nope GET a.test /no/such/page
check "$([ "$(status nope)" = 404 ] && echo ok)" "an unknown path: 404"

# 2b. The cache: host + path keys, until the epoch changes.
req a2 GET a.test /
req b2 GET b.test /
SA=$(stamp a1); SB=$(stamp b1)
check "$([ -n "$SA" ] && [ "$(stamp a2)" = "$SA" ] && [ "$(stamp b2)" = "$SB" ] && [ "$SA" != "$SB" ] && echo ok)" "a second GET of each host is the cached page: same stamp; the two hosts have their own entries"
req hh GET a.test / -H "Host: A.Test:$PORT"
check "$([ "$(status hh)" = 200 ] && body_has hh 'Home A' && echo ok)" "the Host header is matched lower-case without its port"
req ts GET a.test /about/
check "$([ "$(status ts)" = 308 ] && [ "$(loc ts)" = /about ] && echo ok)" "a trailing slash on a catch-all path: 308 to the path, got $(status ts) '$(loc ts)'"
req ah HEAD a.test /
check "$([ "$(status ah)" = 200 ] && echo ok)" "HEAD a.test/: 200"

# 2c. Sitemap and robots per host.
req sa GET a.test /sitemap.xml
check "$([ "$(status sa)" = 200 ] && body_has sa '<loc>https://a.test/</loc>' && body_has sa '<loc>https://a.test/about</loc>' && ! body_has sa 'b.test' && ! body_has sa '/admin' && echo ok)" "a.test/sitemap.xml: A's nodes on https://a.test, nothing from B, no admin page"
req sb GET b.test /sitemap.xml
check "$([ "$(status sb)" = 200 ] && body_has sb '<loc>https://b.test/</loc>' && ! body_has sb 'about' && ! body_has sb 'a.test' && echo ok)" "b.test/sitemap.xml: B's nodes on https://b.test"
req ra GET a.test /robots.txt
check "$([ "$(status ra)" = 200 ] && body_has ra 'Disallow: /admin' && body_has ra 'Sitemap: https://a.test/sitemap.xml' && echo ok)" "robots.txt from fn robots, with the host's sitemap line"

# 2d. The admin guard covers the package's pages and the module mounted inside it.
for p in /admin /admin/media /admin/nodes/1 /admin/shop /admin/shop/orders; do
  req g GET admin.test "$p"
  check "$([ "$(status g)" = 303 ] && [ "$(loc g)" = "/admin/login?next=$(printf '%s' "$p" | sed 's|/|%2F|g')" ] && echo ok)" "$p without a session: 303 to /admin/login?next=..., got $(status g) '$(loc g)'"
done
req lp GET admin.test '/admin/login?next=%2Fadmin%2Fshop'
check "$([ "$(status lp)" = 200 ] && body_has lp 'name="_csrf"' && has_header lp 'set-cookie: gw_csrf=' && echo ok)" "/admin/login: open, with a CSRF token and cookie"
TOK=$(token lp)
req lps GET admin.test /admin/login -H 'X-Forwarded-Proto: https' -b /dev/null -c /dev/null
check "$(has_header lps 'set-cookie: __host-gw_csrf=' && grep -qi '^set-cookie: __host-gw_csrf=.*path=/.*secure' "$WORK/lps.h" && echo ok)" "behind HTTPS the CSRF cookie of a mounted page is __Host-, Path=/ and Secure"
req lbad POST admin.test /admin/login/submit -d 'username=admin&password=x'
check "$([ "$(status lbad)" = 403 ] && echo ok)" "login POST without a CSRF token: 403"
req lpw POST admin.test /admin/login/submit --data-urlencode "_csrf=$TOK" -d 'username=admin&password=wrong'
check "$([ "$(status lpw)" = 303 ] && [ "$(loc lpw)" = /admin/login?error=1 ] && echo ok)" "a wrong password: 303 back to the login page"
req lok POST admin.test /admin/login/submit --data-urlencode "_csrf=$TOK" -d 'username=admin&password=correct+horse&next=%2Fadmin%2Fshop'
check "$([ "$(status lok)" = 303 ] && [ "$(loc lok)" = /admin/shop ] && has_header lok 'set-cookie: gw_session=' && echo ok)" "login: 303 to the next page, with the session cookie, got $(status lok) '$(loc lok)'"
check "$(grep -qi 'set-cookie: gw_session=.*path=/' "$WORK/lok.h" && grep -qi 'set-cookie: gw_session=.*httponly' "$WORK/lok.h" && echo ok)" "the session cookie is Path=/ and HttpOnly (it serves the mount)"

# 2e. Logged in: the package's pages, layout and middleware, and the nested module.
req d GET admin.test /admin
check "$([ "$(status d)" = 200 ] && body_has d 'admin-home' && body_has d 'data-admin-layout' && body_has d 'data-root-layout' && has_header d 'x-admin: 1' && echo ok)" "/admin: the package page inside the package's layout and the host's root layout, with the package middleware's header"
check "$(body_has d 'class="pill"' && body_has d 'data-component="Pill"' && body_has d '/admin/nodes/1' && body_has d 'b.test/' && echo ok)" "/admin: the package component (Pill) and the node list from the shared store"
req sh GET admin.test /admin/shop
check "$([ "$(status sh)" = 200 ] && body_has sh 'shop-home' && body_has sh 'class="shop-tag"' && body_has sh 'data-admin-layout' && body_has sh 'data-root-layout' && has_header sh 'x-admin: 1' && echo ok)" "/admin/shop: the nested module's page and component, in the outer package's layout, with its middleware"
check "$(has_header sh 'x-shop: 1' && body_has sh 'data-shop-layout' && echo ok)" "the module's own layout and middleware apply too"
check "$([ "$(awk '/data-root-layout/{a=NR} /data-admin-layout/{b=NR} /data-shop-layout/{c=NR} /shop-home/{d=NR} END{print (a<=b && b<c && c<d) ? "ok" : "no"}' "$WORK/sh.b")" = ok ] && echo ok)" "the layouts nest: the host's, then the package's, then the module's, around the page"
req so GET admin.test /admin/shop/orders
check "$([ "$(status so)" = 200 ] && body_has so 'orders=42' && body_has so 'data-admin-layout' && echo ok)" "/admin/shop/orders: the module's lib code through its page"
check "$(body_has d '/_gw/Pill.js' && body_has sh '/_gw/ShopTag.js' && echo ok)" "the components of both packages are loaded from /_gw"
ASSET=$(sed -n 's|.*href="\(/admin/admin\.[0-9a-f]\{8\}\.css\)".*|\1|p' "$WORK/d.b" | head -n 1)
check "$([ -n "$ASSET" ] && echo ok)" "the package layout's @asset is a hashed URL under the mount: '$ASSET'"
req css GET admin.test "$ASSET"
check "$([ "$(status css)" = 200 ] && [ "$(header css cache-control)" = 'public, max-age=31536000, immutable' ] && body_has css 'border-radius' && echo ok)" "the package's public file at its hashed URL: 200, immutable"
req css2 GET admin.test /admin/admin.css
check "$([ "$(status css2)" = 200 ] && echo ok)" "and at its plain URL"
req pill GET admin.test /_gw/Pill.js
check "$([ "$(status pill)" = 200 ] && echo ok)" "/_gw/Pill.js: the package component's script"

# 2f. An edit through the views-generated form.
req e GET admin.test /admin/nodes/1
ET=$(token e)
check "$([ "$(status e)" = 200 ] && [ -n "$ET" ] && body_has e 'name="t.title"' && body_has e 'value="Home A"' && body_has e '<option selected>Light</option>' && body_has e 'name="w.body"' && body_has e 'data-editor="markdown"' && body_has e 'Shown under the title.' && echo ok)" "/admin/nodes/1: the form generated from the views (page type and widget), filled from storage"
req enocsrf POST admin.test /admin/nodes/1 -d 't.title=Nope'
check "$([ "$(status enocsrf)" = 403 ] && echo ok)" "saving without a CSRF token: 403"
req ebad POST admin.test /admin/nodes/1 --data-urlencode "_csrf=$ET" --data-urlencode 't.title=x' --data-urlencode 't.theme=Light' --data-urlencode 'w.body=text'
check "$([ "$(status ebad)" = 422 ] && body_has ebad 'Use at least 2 characters.' && body_has ebad 'id="t.title-error"' && body_has ebad 'value="x"' && body_has ebad 'aria-invalid="true"' && echo ok)" "a title that fails the view's validate: 422, the message at the field (prefix included) and the typed value shown again"
req a3 GET a.test /
check "$([ "$(stamp a3)" = "$SA" ] && body_has a3 'Home A' && echo ok)" "the failed save changed nothing: the page is still the cached one"
req esave POST admin.test /admin/nodes/1 --data-urlencode "_csrf=$ET" --data-urlencode 't.title=Home A v2' --data-urlencode 't.theme=Dark' --data-urlencode 't.intro=changed intro' --data-urlencode 'w.body=Edited **text** here'
check "$([ "$(status esave)" = 303 ] && [ "$(loc esave)" = '/admin/nodes/1?saved=1' ] && echo ok)" "saving: 303 to the edit page, got $(status esave) '$(loc esave)'"
req a4 GET a.test /
req b4 GET b.test /
check "$([ "$(status a4)" = 200 ] && body_has a4 'Home A v2' && body_has a4 'changed intro' && body_has a4 'class="article dark"' && body_has a4 '<strong>text</strong>' && echo ok)" "a.test/ shows the saved page"
check "$([ "$(stamp a4)" != "$SA" ] && [ "$(stamp b4)" != "$SB" ] && echo ok)" "epoch_bump: both hosts' cached pages were dropped and rendered again"
check "$(body_has b4 'Home B' && body_has b4 'Hello <strong>world</strong> from B' && ! body_has b4 'Home A v2' && echo ok)" "b.test/ still shows channel B's own content"
req a5 GET a.test /
req b5 GET b.test /
check "$([ "$(stamp a5)" = "$(stamp a4)" ] && [ "$(stamp b5)" = "$(stamp b4)" ] && echo ok)" "and the new pages are cached again"
req ee GET admin.test "/admin/nodes/1?saved=1"
check "$(body_has ee 'id="saved"' && body_has ee 'value="Home A v2"' && body_has ee '<option selected>Dark</option>' && echo ok)" "the edit page shows the saved values and the notice: $(grep -o 'id="saved"\|value="Home[^"]*"\|selected>[A-Za-z]*' "$WORK/ee.b" | tr '\n' ' ')"
req d1 GET admin.test /admin
check "$(body_has d1 'rev 2' && echo ok)" "the dashboard shows the new revision"

# 2g. Reserved prefixes: a new slug may not shadow a route, a mount or a public file.
for slug in /admin /media /admin/x /_gw /sitemap.xml 'bad slug' /UPPER; do
  req rs POST admin.test /admin/new --data-urlencode "_csrf=$ET" --data-urlencode 'channel=1' --data-urlencode "path=$slug"
  check "$(refused rs && echo ok)" "creating '$slug' is refused, got $(status rs) '$(loc rs)'"
done
req rn POST admin.test /admin/new --data-urlencode "_csrf=$ET" --data-urlencode 'channel=1' --data-urlencode 'path=/news'
check "$([ "$(status rn)" = 303 ] && [ "$(loc rn)" = /admin/nodes/4 ] && echo ok)" "creating /news: 303 to its edit page, got '$(loc rn)'"
req nw GET a.test /news
check "$([ "$(status nw)" = 200 ] && body_has nw 'site-a' && echo ok)" "a.test/news: the new node, from the defaults of its page type"
req nw2 GET b.test /news
check "$([ "$(status nw2)" = 404 ] && echo ok)" "b.test/news: 404"
req rd POST admin.test /admin/new --data-urlencode "_csrf=$ET" --data-urlencode 'channel=1' --data-urlencode 'path=/news'
check "$(refused rd && echo ok)" "a path that exists is refused"

# 2h. Media: upload through the admin, serve through gweb::send_file.
req mp GET admin.test /admin/media
MT=$(token mp)
printf 'hello media file' > "$WORK/up.txt"
req mu POST admin.test /admin/media -F "_csrf=$MT" -F "file=@$WORK/up.txt;type=text/plain"
check "$([ "$(status mu)" = 303 ] && [ "$(loc mu)" = /admin/media ] && echo ok)" "upload: 303 to the media page, got $(status mu) '$(loc mu)'"
req ml GET admin.test /admin/media
check "$(body_has ml '<a href="/media/m1/up.txt">up.txt</a> 16' && echo ok)" "the media page lists the upload"
dd if=/dev/zero of="$WORK/six.bin" bs=1048576 count=6 2>/dev/null
req mbig POST admin.test /admin/media -F "_csrf=$MT" -F "file=@$WORK/six.bin"
check "$([ "$(status mbig)" = 413 ] && echo ok)" "an upload over the package page's MAX_UPLOAD: 413, got $(status mbig)"
req m1 GET a.test /media/m1/up.txt
ETAG=$(header m1 etag)
check "$([ "$(status m1)" = 200 ] && [ "$(cat "$WORK/m1.b")" = 'hello media file' ] && [ -n "$ETAG" ] && echo ok)" "GET /media/m1/up.txt: 200 and the bytes"
check "$([ "$(header m1 content-type)" = 'text/plain; charset=utf-8' ] && [ "$(header m1 cache-control)" = 'public, max-age=31536000, immutable' ] && echo ok)" "its Content-Type is from the extension and it is immutable"
req m2 GET b.test /media/m1/up.txt -H "If-None-Match: $ETAG"
check "$([ "$(status m2)" = 304 ] && [ ! -s "$WORK/m2.b" ] && [ "$(header m2 etag)" = "$ETAG" ] && echo ok)" "with If-None-Match: 304 (on the other host too: the library is shared)"
req m3 GET a.test /media/m1/up.txt -H 'If-None-Match: "other"'
check "$([ "$(status m3)" = 200 ] && echo ok)" "another ETag: 200"
req m4 HEAD a.test /media/m1/up.txt
check "$([ "$(status m4)" = 200 ] && [ "$(header m4 content-length)" = 16 ] && [ "$(header m4 etag)" = "$ETAG" ] && [ ! -s "$WORK/m4.b" ] && echo ok)" "HEAD: 200 with the length and ETag, no body"
req m5 GET a.test /media/m1/missing.txt
check "$([ "$(status m5)" = 404 ] && echo ok)" "a missing file: 404"
req m6 GET a.test /media/m99/up.txt
check "$([ "$(status m6)" = 404 ] && echo ok)" "a missing key: 404"
# Hostile paths. curl --path-as-is keeps the dots and encodings as written.
for p in '/media/m1/..%2F..%2Fcms.db' '/media/m1/%2e%2e%2f..%2fcms.db' '/media/..%2Fm1/up.txt' '/media/m1/..' '/media/%2e%2e/up.txt' '/media/m1/.hidden' '/media/m1/up.txt%00' '/media/m1/..%5Cup.txt' '/media/m1%2F..%2F..%2Fcms.db/x'; do
  req hp GET a.test "$p" --path-as-is
  case "$(status hp)" in 404|400) ok ;; *) bad "hostile path $p: expected 404 or 400, got $(status hp)" ;; esac
  check "$(! body_has hp 'CREATE TABLE' && ! body_has hp 'hello media' && echo ok)" "hostile path $p: leaks nothing"
done
# A symlink inside the root that leaves it, and a big file.
echo "outside the media root" > "$WORK/secret.txt"
ln -s "$WORK/secret.txt" "$WORK/site/data/media/m1/link.txt"
req sl GET a.test /media/m1/link.txt
check "$([ "$(status sl)" = 404 ] && ! body_has sl 'outside the media root' && echo ok)" "a symlink that leaves the media root: 404"
ln -s "$WORK/site/data/media/m1/up.txt" "$WORK/site/data/media/m1/inside.txt"
req si GET a.test /media/m1/inside.txt
check "$([ "$(status si)" = 200 ] && [ "$(cat "$WORK/si.b")" = 'hello media file' ] && echo ok)" "a symlink that stays inside the root: 200"
dd if=/dev/zero of="$WORK/site/data/media/m1/big.bin" bs=1048576 count=3 2>/dev/null
req bg GET a.test /media/m1/big.bin
check "$([ "$(status bg)" = 200 ] && [ "$(wc -c < "$WORK/bg.b" | tr -d ' ')" = 3145728 ] && has_header bg 'transfer-encoding: chunked' && [ "$(header bg content-type)" = application/octet-stream ] && echo ok)" "a 3 MiB file: streamed in chunks, all bytes arrive"
BETAG=$(header bg etag)
req bg2 GET a.test /media/m1/big.bin -H "If-None-Match: $BETAG"
check "$([ "$(status bg2)" = 304 ] && echo ok)" "the big file: 304 on a matching ETag, nothing streamed"
req bg3 HEAD a.test /media/m1/big.bin
check "$([ "$(status bg3)" = 200 ] && [ ! -s "$WORK/bg3.b" ] && echo ok)" "the big file: HEAD is 200 with no body"
req am GET a.test /media/m1/up.txt
check "$([ "$(status am)" = 200 ] && echo ok)" "the server still answers after the streamed and refused requests"

# 2i. Logout, then the guard again.
# 2i. Four workers: every worker drops its cache at the epoch, and every reader sees the committed write.
stop
(cd "$WORK/site" && exec ./.gooseweb/server --port "$PORT" --workers 4 >"$WORK/server4.log" 2>&1) &
PID=$!
deadline=$(( $(date +%s) + 30 ))
up=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  alive || break
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/"; then up=1; break; fi
  sleep 0.2
done
if [ -z "$up" ]; then
  bad "the 4-worker server did not answer"; show "$(cat "$WORK/server4.log" 2>/dev/null)"
else
  stale=0
  for i in 1 2 3 4 5 6 7 8; do
    req w GET a.test / -H 'Connection: close'
    body_has w 'Home A v2' || stale=1
  done
  check "$([ "$stale" = 0 ] && echo ok)" "four workers: the page before the edit, 8 fresh connections"
  req we GET admin.test /admin/nodes/1
  WT=$(token we)
  req ws POST admin.test /admin/nodes/1 --data-urlencode "_csrf=$WT" --data-urlencode 't.title=Home A v3' --data-urlencode 't.theme=Light' --data-urlencode 'w.body=Edited again'
  check "$([ "$(status ws)" = 303 ] && echo ok)" "the edit on a 4-worker server: 303"
  stale=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    req w GET a.test / -H 'Connection: close'
    body_has w 'Home A v3' || stale=1
  done
  check "$([ "$stale" = 0 ] && echo ok)" "four workers: every connection shows the new page after epoch_bump (none served a stale cache)"
fi

# 2j. Logout, then the guard again.
req lo POST admin.test /admin/logout --data-urlencode "_csrf=$(token we)"
check "$([ "$(status lo)" = 303 ] && [ "$(loc lo)" = /admin/login ] && echo ok)" "logout: 303 to the login page, got $(status lo) '$(loc lo)'"
req d2 GET admin.test /admin/shop/orders
check "$([ "$(status d2)" = 303 ] && echo ok)" "after logout /admin/shop/orders is guarded again"
if alive; then ok; else bad "the server died during the run:"; show "$(tail -n 20 "$WORK/server.log")"; fi
stop

# 3. gweb test: package views and components in the host project.
if out=$("$GWEB" -C "$WORK/site" test 2>&1); then
  case "$out" in *"routes: 6 tests, "*" 0 failed"*) ok ;; *) bad "gweb test did not print 'routes: 6 tests ... 0 failed':"; show "$out" ;; esac
else
  bad "gweb test of the host project failed:"; show "$out"
fi

echo "cmsready.sh: $pass of $((pass + fail)) checks passed"
[ "$fail" -eq 0 ]
