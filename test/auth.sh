#!/bin/sh
# goose-web's auth and security suite (DESIGN-ADDENDUM-13, step 6).
#
#   GOOSE=/path/to/goose test/auth.sh
#
# test/auth/site is built and started with --dev-id 5 (so the environment is
# "development" and .env.development supplies WEB_SECRET); curl checks the login
# flow with a cookie jar, the default headers, CSP, CORS and the rate limit.
# Last, the production build without WEB_SECRET must refuse to start.
#
# Needs curl and python3, and gweb built beside this folder (goose build -o gweb
# cli/gweb.goose).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
if [ -z "${GOOSE:-}" ]; then echo "auth.sh: set GOOSE to the goose compiler" >&2; exit 2; fi
if [ ! -x "$GWEB" ]; then echo "auth.sh: $GWEB is missing; build it with: $GOOSE build -o gweb cli/gweb.goose" >&2; exit 2; fi
PORT=${PORT:-3995}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-auth.XXXXXX")
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
JAR="$WORK/jar"
# req NAME METHOD PATH [curl args]: status in $WORK/NAME.status, headers in
# NAME.h (lower case), body in NAME.b. The cookie jar is always on.
req() {
  name=$1; method=$2; path=$3; shift 3
  curl -s -b "$JAR" -c "$JAR" -X "$method" -D "$WORK/$name.h.raw" -o "$WORK/$name.b" -w '%{http_code}' "$@" "$URL$path" > "$WORK/$name.status"
  tr -d '\r' < "$WORK/$name.h.raw" | tr 'A-Z' 'a-z' > "$WORK/$name.h"
}
status() { cat "$WORK/$1.status"; }
has_header() { grep -q "^$2" "$WORK/$1.h"; }
body_has() { grep -qF -- "$2" "$WORK/$1.b"; }
# loc NAME: the Location value with its case kept.
loc() { tr -d '\r' < "$WORK/$1.h.raw" | sed -n 's/^[Ll]ocation: //p'; }
# token NAME: the _csrf value in NAME's body.
token() { sed -n 's/.*name="_csrf" value="\([^"]*\)".*/\1/p' "$WORK/$1.b" | head -n 1; }

# start [ENV=VALUE ...]: the built server on $PORT, waiting until it answers.
start() {
  (cd "$WORK/ok" && exec env "$@" ./.gooseweb/server --port "$PORT" --dev-id 5 >/dev/null 2>&1) &
  PID=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    if curl -s -o /dev/null "$URL/"; then return 0; fi
  done
  return 1
}
stop() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null
  PID=""
}

cp -R "$HERE/auth/site" "$WORK/ok"
if ! out=$("$GWEB" -C "$WORK/ok" build 2>&1); then
  bad "gweb build of the site"; echo "$out"
  echo "auth.sh: $pass passed, $fail failed"
  exit 1
fi

# 1. Login, session, logout, headers, CORS, rate limit.
if ! start A=1; then
  bad "the server did not answer on port $PORT"
else
  req g0 GET /admin
  check "$([ "$(status g0)" = 303 ] && [ "$(loc g0)" = '/login?next=%2Fadmin' ] && echo ok)" "/admin without a cookie: 303 to /login?next=%2Fadmin, got $(status g0) '$(loc g0)'"

  req lp GET '/login?next=%2Fadmin'
  TK=$(token lp)
  check "$([ "$(status lp)" = 200 ] && [ -n "$TK" ] && body_has lp 'name="next" value="/admin"' && ! body_has lp 'Wrong username' && echo ok)" "GET /login: 200, a form with a CSRF token and next"

  req w1 POST /login/submit -d "username=admin&password=wrong&next=%2Fadmin&_csrf=$TK"
  req w2 POST /login/submit -d "username=nobody&password=wrong&next=%2Fadmin&_csrf=$TK"
  check "$([ "$(status w1)" = 303 ] && [ "$(status w2)" = 303 ] && [ "$(loc w1)" = "$(loc w2)" ] && [ -n "$(loc w1)" ] && ! has_header w1 'set-cookie: gw_session' && echo ok)" "wrong password and unknown user: the same 303, no session"
  req e1 GET "$(loc w1)"
  req e2 GET "$(loc w2)"
  check "$(body_has e1 'Wrong username or password.' && cmp -s "$WORK/e1.b" "$WORK/e2.b" && echo ok)" "wrong password and unknown user: the same page and message"

  req good POST /login/submit -d "username=admin&password=correct+horse&next=%2Fadmin&_csrf=$TK"
  check "$([ "$(status good)" = 303 ] && [ "$(loc good)" = /admin ] && echo ok)" "good login: 303 to next, got $(status good) '$(loc good)'"
  check "$(has_header good 'set-cookie: gw_session=' && has_header good 'set-cookie: gw_csrf=;' && grep '^set-cookie: gw_csrf=;' "$WORK/good.h" | grep -q 'max-age=0' && echo ok)" "good login: a gw_session cookie and a gw_csrf clear line"
  check "$(has_header good 'cache-control: no-store' && echo ok)" "good login: no-store"
  req lpe GET /login
  req evil POST /login/submit -d "username=admin&password=correct+horse&next=%2F%2Fevil.example&_csrf=$(token lpe)"
  check "$([ "$(loc evil)" = /admin ] && echo ok)" "login with next=//evil.example: 303 to /admin"

  req ad GET /admin
  check "$([ "$(status ad)" = 200 ] && body_has ad '<b id="uid">1</b>' && echo ok)" "/admin with the cookie: 200 and uid 1"
  check "$(has_header ad 'x-content-type-options: nosniff' && has_header ad 'referrer-policy: strict-origin-when-cross-origin' && has_header ad 'x-frame-options: sameorigin' && echo ok)" "/admin: the three default security headers"
  check "$(! has_header ad 'content-security-policy' && echo ok)" "CSP is off by default"

  SES=$(tr -d '\r' < "$WORK/good.h.raw" | sed -n 's/^[Ss]et-[Cc]ookie: \(gw_session=[^;]*\);.*/\1/p' | head -n 1)
  TAMP="${SES%?}"
  case "$SES" in *A) TAMP="${TAMP}B" ;; *) TAMP="${TAMP}A" ;; esac
  curl -s -o /dev/null -D "$WORK/tamp.h.raw" -w '%{http_code}' -H "Cookie: $TAMP" "$URL/admin" > "$WORK/tamp.status"
  tr -d '\r' < "$WORK/tamp.h.raw" | tr 'A-Z' 'a-z' > "$WORK/tamp.h"
  check "$([ "$(status tamp)" = 303 ] && has_header tamp 'location: /login' && echo ok)" "/admin with a tampered cookie: 303 to /login"

  TK2=$(token ad)
  req lo POST /logout -d "_csrf=$TK2"
  check "$([ "$(status lo)" = 303 ] && [ "$(loc lo)" = /login ] && grep '^set-cookie: gw_session=;' "$WORK/lo.h" | grep -q 'max-age=0' && echo ok)" "POST /logout: 303 to /login and the session cookie cleared"
  req ad2 GET /admin
  check "$([ "$(status ad2)" = 303 ] && echo ok)" "/admin after logout: 303"
  req lo2 GET /logout
  check "$([ "$(status lo2)" = 405 ] && echo ok)" "GET /logout: 405 (logout is POST only)"

  req root GET /
  check "$(has_header root 'x-content-type-options: nosniff' && echo ok)" "GET /: default security headers"

  req pf OPTIONS /api/ping -H 'Origin: https://ok.example' -H 'Access-Control-Request-Method: POST'
  check "$([ "$(status pf)" = 204 ] && has_header pf 'access-control-allow-origin: https://ok.example' && has_header pf 'access-control-allow-methods:' && has_header pf 'vary: origin' && echo ok)" "CORS preflight from an allowed origin: 204 and the allow headers"
  req pf2 OPTIONS /api/ping -H 'Origin: https://evil.example' -H 'Access-Control-Request-Method: POST'
  check "$([ "$(status pf2)" = 403 ] && ! has_header pf2 'access-control-allow-origin' && echo ok)" "CORS preflight from another origin: 403, no allow header"
  req pg GET /api/ping -H 'Origin: https://ok.example'
  check "$([ "$(status pg)" = 200 ] && has_header pg 'access-control-allow-origin: https://ok.example' && body_has pg '"ok":true' && echo ok)" "GET /api/ping from an allowed origin: JSON and the allow header"
  req pp POST /api/ping -H 'Origin: https://ok.example' -H 'Sec-Fetch-Site: cross-site'
  check "$([ "$(status pp)" = 200 ] && echo ok)" "POST /api/ping (const CSRF = false) cross-site: 200"

  # The login limit is 10 a minute for this address, and every login POST above used one:
  # wrong, unknown, good, evil. Fresh user names keep the per-user limit out of the way.
  req lp3 GET /login
  TK3=$(token lp3)
  used=4
  n=0
  while [ "$used" -lt 10 ]; do
    n=$((n + 1)); used=$((used + 1))
    req f$n POST /login/submit -d "username=flood$n&password=x&_csrf=$TK3"
    [ "$(status f$n)" = 303 ] || bad "login POST $used: wanted 303, got $(status f$n)"
  done
  req f11 POST /login/submit -d "username=flood99&password=x&_csrf=$TK3"
  check "$([ "$(status f11)" = 429 ] && grep -q '^retry-after: [0-9]' "$WORK/f11.h" && body_has f11 'too many requests' && echo ok)" "the 11th login POST in a minute: 429 with Retry-After, got $(status f11)"
  stop
fi

# 2. CSP is opt-in.
if ! start WEB_CSP=1; then
  bad "the server with WEB_CSP=1 did not answer on port $PORT"
else
  req cs GET /
  # The nonce is case-sensitive, so it is read from the raw headers, not the lower-cased copy.
  NONCE=$(tr -d '\r' < "$WORK/cs.h.raw" | sed -n "s/^[Cc]ontent-[Ss]ecurity-[Pp]olicy: .*'nonce-\([A-Za-z0-9_-]*\)'.*/\1/p" | head -n 1)
  check "$([ "${#NONCE}" = 22 ] && grep -qF "script-src 'self' 'nonce-$NONCE'" "$WORK/cs.h.raw" && echo ok)" "WEB_CSP=1: a CSP header with a 22-byte nonce"
  check "$([ -n "$NONCE" ] && [ "$(grep -oF "<script nonce=\"$NONCE\">" "$WORK/cs.b" | wc -l | tr -d ' ')" -ge 2 ] && echo ok)" "WEB_CSP=1: the page script and the dev script carry the nonce"
  stop
fi

# 3. Production without WEB_SECRET refuses to start.
cp -R "$WORK/ok" "$WORK/prod"
rm -f "$WORK/prod/.env.development" "$WORK/prod/.env.local" "$WORK/prod/.env.production.local" "$WORK/prod/.env.production"
rm -rf "$WORK/prod/.gooseweb.dev"
out=$(cd "$WORK/prod" && env -u WEB_SECRET GWEB_ENV=production ./.gooseweb/server --port "$PORT" 2>&1)
code=$?
check "$([ "$code" = 2 ] && case "$out" in (*"set WEB_SECRET"*) echo ok ;; esac)" "production without WEB_SECRET: exit 2 and the message, got $code '$out'"

echo "auth.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
