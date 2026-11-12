#!/bin/sh
# goose-web's fragment suite (DESIGN-ADDENDUM-4, section 10).
#
#   GOOSE=/path/to/goose test/fragments.sh
#
# 1. test/fragments/site is built and started with --dev-id 5; curl checks the
#    fragment replies, page POST, the refusals, the script tags, /_gw/gwi.js,
#    and that a page with no fragment generates what it did before fragments.
# 2. Every error of DESIGN-ADDENDUM-4 sections 2, 3 and 5, each in a copy of the
#    site, must fail gweb build with its message at its line.
# 3. gweb routes shows GET,POST and the frag lines.
#
# Needs curl and python3, and gweb built beside this folder (goose build -o gweb
# cli/gweb.goose).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
PORT=${PORT:-3991}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-fragments.XXXXXX")
PID=""
TK=0123456789abcdef0123456789abcdef
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

# req NAME METHOD PATH [curl args]: status in $WORK/NAME.status, headers in
# NAME.h (lower case), body in NAME.b.
URL="http://127.0.0.1:$PORT"
req() {
  name=$1; method=$2; path=$3; shift 3
  curl -s -X "$method" -D "$WORK/$name.h.raw" -o "$WORK/$name.b" -w '%{http_code}' "$@" "$URL$path" > "$WORK/$name.status"
  tr -d '\r' < "$WORK/$name.h.raw" | tr 'A-Z' 'a-z' > "$WORK/$name.h"
}
status() { cat "$WORK/$1.status"; }
has_header() { grep -q "^$2" "$WORK/$1.h"; }
body_has() { grep -qF -- "$2" "$WORK/$1.b"; }
body_count() { grep -oF -- "$2" "$WORK/$1.b" | wc -l | tr -d ' '; }
# substring PART WHOLE: the bytes of PART's body are inside WHOLE's.
substring() {
  python3 -I -c 'import sys; sys.exit(0 if open(sys.argv[1], "rb").read() in open(sys.argv[2], "rb").read() else 1)' "$WORK/$1.b" "$WORK/$2.b"
}

# 1. The site.
cp -R "$HERE/fragments/site" "$WORK/ok"
if out=$("$GWEB" -C "$WORK/ok" build 2>&1); then
  "$WORK/ok/.gooseweb/server" --port "$PORT" --dev-id 5 >/dev/null 2>&1 &
  PID=$!
  up=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    if curl -s -o /dev/null "$URL/"; then up=yes; break; fi
  done
  if [ -z "$up" ]; then
    bad "the server did not answer on port $PORT"
  else
    req whole GET / -H "Cookie: gw_csrf=$TK"
    check "$([ "$(status whole)" = 200 ] && body_has whole '<html' && body_has whole '__gweb/id' && ! has_header whole 'gw-fragment' && echo ok)" "GET /: 200, the whole page with the dev script, no echo"

    req list GET / -H 'GW-Fragment: list' -H "Cookie: gw_csrf=$TK"
    check "$([ "$(status list)" = 200 ] && has_header list 'gw-fragment: list' && echo ok)" "fragment list: 200 and the GW-Fragment echo"
    check "$(has_header list 'cache-control: no-store' && echo ok)" "fragment list: Cache-Control: no-store"
    check "$(! body_has list '__gweb/id' && ! body_has list '<html' && ! body_has list 'gwi.js' && ! body_has list 'gwf.js' && echo ok)" "fragment list: no dev script, no layout, no script tag"
    check "$(substring list whole && echo ok)" "fragment list: its bytes are a substring of the whole page"
    check "$(body_has whole '__gweb/id' && echo ok)" "the whole page has the dev script"
    check "$(body_has list '<form method="post" action="/" gw-target="list">' && ! body_has list 'whole page only' && echo ok)" "fragment list: the region and nothing else"

    req side GET / -H 'GW-Fragment: side' -H "Cookie: gw_csrf=$TK"
    check "$([ "$(cat "$WORK/side.b")" = '<b>7</b>' ] && has_header side 'gw-fragment: side' && substring side whole && echo ok)" "fragment side (the second): exactly its region"

    req nope GET / -H 'GW-Fragment: nope' -H "Cookie: gw_csrf=$TK"
    check "$([ "$(status nope)" = 200 ] && cmp -s "$WORK/nope.b" "$WORK/whole.b" && ! has_header nope 'gw-fragment' && echo ok)" "an unknown fragment name: the whole page, no echo"

    req pf POST / -H 'GW-Fragment: list' -H "Cookie: gw_csrf=$TK" -d 'title=hello&_csrf='"$TK"
    check "$([ "$(status pf)" = 200 ] && has_header pf 'gw-fragment: list' && body_has pf 'hello' && ! body_has pf '<html' && echo ok)" "POST with the header: a fragment"
    req pw POST / -H "Cookie: gw_csrf=$TK" -d 'title=hello&_csrf='"$TK"
    check "$([ "$(status pw)" = 200 ] && body_has pw '<html' && body_has pw 'hello' && ! has_header pw 'gw-fragment' && echo ok)" "POST without the header: the whole page"
    req dec POST / -H 'GW-Fragment: list' -H "Cookie: gw_csrf=$TK" -d 'title=a+b%26c%3Cd%C3%A9x%25&_csrf='"$TK"
    check "$(body_has dec 'a b&amp;c&lt;dé' && body_has dec 'x%' && echo ok)" "web::form decodes +, %26, %3C, UTF-8 and %25"
    req xs POST / -H 'GW-Fragment: list' -H 'Sec-Fetch-Site: cross-site' -H "Cookie: gw_csrf=$TK" -d 'title=hello&_csrf='"$TK"
    check "$([ "$(status xs)" = 403 ] && ! body_has xs 'hello' && body_has xs 'cross-site request refused' && echo ok)" "Sec-Fetch-Site: cross-site gives 403"
    req ss POST / -H 'GW-Fragment: list' -H 'Sec-Fetch-Site: same-origin' -H "Cookie: gw_csrf=$TK" -d 'title=hello&_csrf='"$TK"
    check "$([ "$(status ss)" = 200 ] && echo ok)" "Sec-Fetch-Site: same-origin is allowed"
    req put PUT /
    check "$([ "$(status put)" = 405 ] && has_header put 'allow: get, head, post, options' && echo ok)" "PUT gives 405 with Allow: GET, HEAD, POST, OPTIONS"
    req opt OPTIONS /
    check "$(has_header opt 'allow: get, head, post, options' && echo ok)" "OPTIONS lists POST"
    req r303 POST / -H 'GW-Fragment: list' -H "Cookie: gw_csrf=$TK" -d 'go=1&_csrf='"$TK"
    check "$([ "$(status r303)" = 303 ] && has_header r303 'location: /other' && ! has_header r303 'gw-fragment' && echo ok)" "a 303 from POST passes through"
    req r303b POST / -H "Cookie: gw_csrf=$TK" -d 'go=1&_csrf='"$TK"
    check "$([ "$(status r303b)" = 303 ] && has_header r303b 'location: /other' && echo ok)" "a 303 from POST without the header passes through"
    req plainpost POST /plain -d 'a=1'
    check "$([ "$(status plainpost)" = 405 ] && has_header plainpost 'allow: get, head, options' && echo ok)" "a page without POST still answers 405 to POST"

    req item GET /item/5 -H 'GW-Fragment: card'
    check "$([ "$(cat "$WORK/item.b")" = 'item 5' ] && has_header item 'gw-fragment: card' && echo ok)" "a dynamic page's fragment"
    req item0 GET /item/5
    check "$(body_has item0 '<section id="card">item 5</section>' && echo ok)" "a dynamic page renders whole"
    req miss GET /nowhere -H 'GW-Fragment: list'
    check "$([ "$(status miss)" = 404 ] && ! has_header miss 'gw-fragment' && echo ok)" "a missing page with the header: 404, no echo"

    # The script tag: once for each template that has a gw-target.
    check "$([ "$(body_count whole 'src="/_gw/gwf.js"')" = 2 ] && echo ok)" "GET /: the fragment script tag twice (layout and page)"
    req plain GET /plain
    check "$([ "$(body_count plain 'src="/_gw/gwf.js"')" = 1 ] && echo ok)" "GET /plain: the fragment script tag once (layout only)"
    check "$(body_has whole '<link rel="modulepreload" href="/_gw/gwi.js"><script type="module" src="/_gw/gwf.js"></script><h1>Fragments</h1>' && echo ok)" "the page's tag comes first in the page"
    req rt GET /_gw/gwi.js
    check "$([ "$(status rt)" = 200 ] && has_header rt 'content-type: text/javascript' && echo ok)" "a project with no component serves /_gw/gwi.js"
    req rf GET /_gw/gwf.js
    check "$([ "$(status rf)" = 200 ] && has_header rf 'content-type: text/javascript' && echo ok)" "a project with fragments serves /_gw/gwf.js"
    check "$([ ! -d "$WORK/ok/components" ] && echo ok)" "the site has no components folder"
    check "$(! body_has whole 'gwn.js' && ! body_has plain 'gwn.js' && echo ok)" "a site without gw-boost: no gwn.js tag"
    req nonav GET /_gw/gwn.js
    check "$([ "$(status nonav)" = 404 ] && echo ok)" "a site without gw-boost does not serve /_gw/gwn.js"

    req tk0 GET /
    check "$([ "$(grep -c '^set-cookie: gw_csrf=[0-9a-f]\{32\}; path=/; httponly; samesite=lax$' "$WORK/tk0.h")" = 1 ] && [ "$(grep -c '^set-cookie:' "$WORK/tk0.h")" = 1 ] && has_header tk0 'cache-control: no-store' && body_has tk0 'name="_csrf" value="' && echo ok)" "GET / without a cookie: one gw_csrf cookie, no-store, a _csrf field"
    req tk1 GET / -H "Cookie: gw_csrf=$TK"
    check "$(! has_header tk1 'set-cookie' && body_has tk1 "value=\"$TK\"" && echo ok)" "GET / with the cookie: no Set-Cookie, the same token in the field"
    req tk2 GET /plain
    check "$(! has_header tk2 'set-cookie' && ! has_header tk2 'cache-control' && echo ok)" "GET /plain: no Set-Cookie, no Cache-Control"
    req tk3 POST / -d 'title=hello'
    check "$([ "$(status tk3)" = 403 ] && body_has tk3 'CSRF token missing or wrong' && echo ok)" "POST / without a token: 403 and the message"
    req tk4 POST / -H "Cookie: gw_csrf=$TK" -d '_csrf=0123456789abcdef0123456789abcdee'
    check "$([ "$(status tk4)" = 403 ] && echo ok)" "POST / with a token one digit off: 403"
    req tk5 POST / -H "Cookie: gw_csrf=$TK" -H "X-CSRF-Token: $TK" -d 'title=hello'
    check "$([ "$(status tk5)" = 200 ] && echo ok)" "POST / with the X-CSRF-Token header and no field: 200"
    req tk6 POST / -H "Cookie: gw_csrf=$TK" -H 'Sec-Fetch-Site: same-site' -d "_csrf=$TK"
    check "$([ "$(status tk6)" = 403 ] && body_has tk6 'cross-site request refused' && echo ok)" "Sec-Fetch-Site: same-site gives 403 with a good token"
    req tk7 POST /save
    check "$([ "$(status tk7)" = 403 ] && echo ok)" "POST /save without a token: 403"
    req tk8 POST /save -H "Cookie: gw_csrf=$TK" -H "X-CSRF-Token: $TK"
    check "$([ "$(status tk8)" = 200 ] && body_has tk8 'saved' && echo ok)" "POST /save with the cookie and header: 200"
    req tk9 POST /webhook -H 'Sec-Fetch-Site: cross-site'
    check "$([ "$(status tk9)" = 200 ] && body_has tk9 'hook' && echo ok)" "POST /webhook (const CSRF = false) with no token, cross-site: 200"
    check "$(grep -qF '::CSRF && !web::csrf_ok(req, res)' "$WORK/ok/.gooseweb/main.goose" && echo ok)" "the generated main checks the CSRF constant"
  fi
  kill "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null
  PID=""
  # A page with no fragment generates what it did before fragments.
  if cmp -s "$WORK/ok/.gooseweb/p5_plain_html.goose" "$HERE/fragments/expect_p5_plain_html.goose"; then ok
  else bad "p5_plain_html.goose differs from the stored copy:"; diff "$HERE/fragments/expect_p5_plain_html.goose" "$WORK/ok/.gooseweb/p5_plain_html.goose" | sed 's/^/    /'; fi
else
  bad "gweb build of the site"; echo "$out"
fi

# 1b. A site whose layout has <body gw-boost> (DESIGN-ADDENDUM-12, item 8).
cp -R "$HERE/fragments/boost" "$WORK/boost"
if out=$("$GWEB" -C "$WORK/boost" build 2>&1); then
  BPORT=$((PORT + 1))
  "$WORK/boost/.gooseweb/server" --port "$BPORT" >/dev/null 2>&1 &
  PID=$!
  URL="http://127.0.0.1:$BPORT"
  up=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    if curl -s -o /dev/null "$URL/"; then up=yes; break; fi
  done
  if [ -z "$up" ]; then
    bad "the gw-boost server did not answer on port $BPORT"
  else
    req bhome GET /
    check "$([ "$(status bhome)" = 200 ] && [ "$(body_count bhome 'src="/_gw/gwn.js"')" = 1 ] && body_has bhome '<link rel="modulepreload" href="/_gw/gwi.js"><script type="module" src="/_gw/gwn.js"></script><h1>Boosted home</h1>' && ! body_has bhome 'gwf.js' && echo ok)" "gw-boost: / has the gwn.js tag (once, with the gwi.js preload, no gwf.js)"
    req babout GET /about
    check "$(body_has babout 'src="/_gw/gwn.js"' && echo ok)" "gw-boost: /about has the gwn.js tag"
    req bnav GET /about -H 'GW-Nav: 1'
    check "$([ "$(status bnav)" = 200 ] && body_has bnav '<h1>Boosted about</h1>' && body_has bnav '<body gw-boost>' && echo ok)" "gw-boost: a GW-Nav request gets the whole page"
    req bjs GET /_gw/gwn.js
    check "$([ "$(status bjs)" = 200 ] && has_header bjs 'content-type: text/javascript' && body_has bjs 'GW-Nav' && echo ok)" "gw-boost: /_gw/gwn.js is served as javascript"
    req bjsi GET /_gw/gwi.js
    check "$([ "$(status bjsi)" = 200 ] && echo ok)" "gw-boost: /_gw/gwi.js is served"
  fi
  kill "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null
  PID=""
  URL="http://127.0.0.1:$PORT"
else
  bad "gweb build of the gw-boost site"; echo "$out"
fi

# 2. Expected failures. The page is <p>x</p>, the case on line 2, <p>y</p>.
cp -R "$HERE/fragments/site" "$WORK/f"
rm -rf "$WORK/f/.gooseweb"
PAGE='<p>x</p>
%s
<p>y</p>
'
LAYOUT='<!doctype html>
%s
<body>@slot()</body>
'

# expect_fail FILE TEXT LINE MESSAGE: FILE holds TEXT, and the build must say
# FILE:LINE: error: MESSAGE. FILE is app/page.html (TEXT on its line 2),
# app/layout.html (the same), bare:FILE (the whole file) or a component.
expect_fail() {
  file=$1; text=$2; line=$3; msg=$4
  cp "$HERE/fragments/site/app/page.html" "$WORK/f/app/page.html"
  cp "$HERE/fragments/site/app/page.goose" "$WORK/f/app/page.goose"
  cp "$HERE/fragments/site/app/layout.html" "$WORK/f/app/layout.html"
  rm -rf "$WORK/f/components"
  case "$file" in
    app/page.html) printf "$PAGE" "$text" > "$WORK/f/$file" ;;
    app/layout.html) printf "$LAYOUT" "$text" > "$WORK/f/$file" ;;
    bare:*) file=${file#bare:}; printf '%s\n' "$text" > "$WORK/f/$file" ;;
    *) mkdir -p "$WORK/f/components"
       printf '<script goose>\nstruct State { n: i64 }\nfn f(s: State&) { s.n += 1; }\n</script>\n%s\n' "$text" > "$WORK/f/$file" ;;
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
# Section 2: the fragment tags.
expect_fail app/layout.html '<i id="a">{#fragment a}x{/fragment}</i>' 2 "{#fragment} is for page.html only"
expect_fail app/layout.html '{/fragment}' 2 "{#fragment} is for page.html only"
expect_fail $P '<i id="1a">{#fragment 1a}x{/fragment}</i>' 2 "a fragment name is [A-Za-z][A-Za-z0-9_-]*, at most 64 bytes"
expect_fail $P '<i id="a b">{#fragment a b}x{/fragment}</i>' 2 "a fragment name is [A-Za-z][A-Za-z0-9_-]*, at most 64 bytes"
expect_fail $P '<i>{#fragment }x{/fragment}</i>' 2 "a fragment name is [A-Za-z][A-Za-z0-9_-]*, at most 64 bytes"
LONG=$(printf 'a%.0s' $(seq 1 65))
expect_fail $P "<i id=\"$LONG\">{#fragment $LONG}x{/fragment}</i>" 2 "a fragment name is [A-Za-z][A-Za-z0-9_-]*, at most 64 bytes"
expect_fail $P '{#if true}<i id="a">{#fragment a}x{/fragment}</i>{/if}' 2 "{#fragment} cannot be inside {#if}, {#for} or another {#fragment}"
expect_fail $P '{#for i in 2}<i id="a">{#fragment a}x{/fragment}</i>{/for}' 2 "{#fragment} cannot be inside {#if}, {#for} or another {#fragment}"
expect_fail $P '<i id="a">{#fragment a}<b id="b">{#fragment b}x{/fragment}</b>{/fragment}</i>' 2 "{#fragment} cannot be inside {#if}, {#for} or another {#fragment}"
expect_fail $P '{#fragment a}x{/fragment}</i>' 2 '{#fragment a} goes right after the opening tag that has id="a", on the same line'
expect_fail $P '<i>{#fragment a}x{/fragment}</i>' 2 '{#fragment a} goes right after the opening tag that has id="a", on the same line'
expect_fail $P '<i id="b">{#fragment a}x{/fragment}</i>' 2 '{#fragment a} goes right after the opening tag that has id="a", on the same line'
expect_fail $P '<div data-id="a">{#fragment a}x{/fragment}</div>' 2 '{#fragment a} goes right after the opening tag that has id="a", on the same line'
expect_fail $P '<i id="a"> {#fragment a}x{/fragment}</i>' 2 '{#fragment a} goes right after the opening tag that has id="a", on the same line'
expect_fail $P '<i id="a">x{/fragment}</i>' 2 "{/fragment} does not close an open {#fragment}"
expect_fail $P '<i id="a">{#fragment a}x{/fragment} </i>' 2 "{/fragment} goes right before the closing tag of the element"
expect_fail $P '<i id="a">{#fragment a}x</i>' 2 "{#fragment} is never closed with {/fragment}"
expect_fail $P '<i id="a">{#fragment a}x{/fragment}</i><i id="a">{#fragment a}y{/fragment}</i>' 2 "two fragments named a"
NINE=""
for n in 1 2 3 4 5 6 7 8 9; do NINE="$NINE<i id=\"f$n\">{#fragment f$n}x{/fragment}</i>"; done
expect_fail $P "$NINE" 2 "a page has at most 8 fragments"
expect_fail $P '<i id="a">{#fragment a}@C(1){/fragment}</i>' 2 "@C() cannot be inside {#fragment} (fragments v1)"
expect_fail components/C.gshtml '<i id="a">{#fragment a}x{/fragment}</i>' 5 "unknown tag {#fragment a}"
# Section 3: page.goose.
expect_fail bare:app/page.goose 'fn POST(req: const http::Request&, ctx: web::Ctx&) -> i64 { return 0; }' 0 "fn POST( needs fn load( beside it"
# Section 5: gw-target and its URL.
expect_fail $P '<div gw-target="a">x</div>' 2 'gw-target goes on <a href="..."> or <form>, with the whole opening tag on one line'
expect_fail $P '<a href="/" gw-target="a"' 2 'gw-target goes on <a href="..."> or <form>, with the whole opening tag on one line'
expect_fail $P '<a href="/" gw-target="a b">x</a>' 2 'gw-target="a b" takes a fragment name'
expect_fail $P '<a href="/" gw-target="{props.n}">x</a>' 2 'gw-target="{props.n}" takes a fragment name'
expect_fail $P '<a href="other" gw-target="a">x</a>' 2 "a gw-target URL starts with / (or is empty or starts with ? for the page itself)"
expect_fail $P '<a href="{props.n}" gw-target="a">x</a>' 2 "a gw-target URL starts with / (or is empty or starts with ? for the page itself)"
expect_fail app/layout.html '<a href="?x" gw-target="a">x</a>' 2 "gw-target here needs a path starting with /"
expect_fail $P '<form method="put" action="/" gw-target="list">x</form>' 2 "gw-target: a form's method is get or post"
expect_fail $P '<a href="/zzz" gw-target="a">x</a>' 2 "gw-target: no page matches /zzz"
expect_fail $P '<a href="/api" gw-target="a">x</a>' 2 "gw-target: /api is a route.goose; fragments come from pages"
expect_fail $P '<a href="/plain" gw-target="a">x</a>' 2 "gw-target: app/plain/page.html has no {#fragment a}"
expect_fail $P '<a href="?x" gw-target="a">x</a>' 2 "gw-target: app/page.html has no {#fragment a}"
expect_fail $P '<form method="post" action="/other" gw-target="a">x</form>' 2 'gw-target: method="post" needs fn POST( in app/other/page.goose'
# CSRF constant (DESIGN-ADDENDUM-7).
expect_fail bare:app/api/route.goose 'const CSRF = 0;' 1 "write const CSRF = false; to turn off this route's CSRF check (or const CSRF = true;)"
expect_fail bare:app/page.goose 'const CSRF = false;' 1 "const CSRF belongs in route.goose; a page's POST always checks the token"

# 3. gweb routes.
routes=$("$GWEB" -C "$HERE/fragments/site" routes 2>&1)
for want in "page   GET,POST" "frag   list" "frag   side" "frag   card" "frag   a "; do
  case "$routes" in *"$want"*) ok ;; *) bad "gweb routes lacks '$want':"; echo "$routes" | sed 's/^/    /' ;; esac
done
case "$routes" in *"page   GET                  /plain"*) ok ;; *) bad "gweb routes: /plain is page GET:"; echo "$routes" | sed 's/^/    /' ;; esac

echo "fragments.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
