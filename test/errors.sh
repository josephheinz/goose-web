#!/bin/sh
# gweb's error pages and crash replies suite (DESIGN-ADDENDUM-14, D10 to D13, step 5).
#
#   GOOSE=/path/to/goose test/errors.sh
#
# test/errors/site is built and started with one worker, so every crash also shows that the
# worker came back. curl checks:
#   - gweb::fail: the status, the nearest error.html inside its layouts, the id in body and log
#   - crashes: 500 with Connection: close, the next request on a new connection works
#   - nested error.html wins; it renders inside the layouts at or above its own folder
#   - a crashing layout above the error file: attempt 2, the bare error.html
#   - a crashing error.html: the fixed plain-text 500
#   - a route.goose crash and a route fail: JSON {"error":..,"id":..}
#   - --dev-id: gw-dev-error before the dev script, with the request; without it, no detail
#   - D14: a page POST taking res that writes a 429 and calls gweb::done; a page POST's gweb::fail(429)
#   - step 7: gweb dev --once writes errors.txt with a marked 5-line excerpt after a build error
#   - informational: plaintext requests per second (see BENCH below)
#
# Needs curl, python3 and gweb built beside this folder (goose build -o gweb cli/gweb.goose).
# Layout: see the note in test/forms.sh about goose-net and git worktrees.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
PORT=${PORT:-3993}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-errors.XXXXXX")
LOG="$WORK/server.log"
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
# body_id NAME: the 16 hex digits of the id in an error page (id="err-id") or a JSON error.
body_id() {
  grep -oE 'id="err-id">[0-9a-f]{16}|"id":"[0-9a-f]{16}"' "$WORK/$1.b" | head -n 1 | grep -oE '[0-9a-f]{16}'
}
# logged ID STATUS METHOD TARGET: the server log has the error line for that id.
logged() {
  grep -qE "gweb: error $1: $2 $3 $4: " "$LOG"
}

start_server() {
  : > "$LOG"
  (cd "$WORK/ok" && exec .gooseweb/server --port "$PORT" --workers 1 "$@" >> "$LOG" 2>&1) &
  PID=$!
  up=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    if curl -s -o /dev/null "$URL/"; then up=yes; break; fi
  done
  [ -n "$up" ]
}
stop_server() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  [ -n "$PID" ] && wait "$PID" 2>/dev/null
  PID=""
}

cp -R "$HERE/errors/site" "$WORK/ok"
if ! out=$("$GWEB" -C "$WORK/ok" build 2>&1); then
  bad "gweb build of the site"; echo "$out"
  echo "errors.sh: $pass passed, $fail failed"
  exit 1
fi

# 1. Production: no --dev-id.
if ! start_server; then
  bad "the server did not answer on port $PORT"
else
  # A deliberate error: 503 through the root error.html, inside the root layout.
  req f GET /fail
  check "$([ "$(status f)" = 503 ] && echo ok)" "/fail: 503"
  check "$(body_has f '<h1 id="root-error">503 Down for maintenance.</h1>' && body_has f 'id="root-layout"' && ! body_has f 'id="crashed"' && echo ok)" "/fail: root error.html with err.status and err.message, inside the root layout, not crashed"
  check "$(has_header f 'content-type: text/html' && echo ok)" "/fail: HTML"
  id=$(body_id f)
  check "$([ -n "$id" ] && logged "$id" 503 GET /fail && grep -qF 'Down for maintenance.' "$LOG" && echo ok)" "/fail: the log line gweb: error <id>: 503 GET /fail: <message> has the page's id"
  check "$(! body_has f 'gw-dev-error' && ! body_has f '__gweb/id' && echo ok)" "/fail: no dev detail and no dev script without --dev-id"

  # A crash: 500, Connection: close, the next request works.
  req c GET /crash
  check "$([ "$(status c)" = 500 ] && has_header c 'connection: close' && echo ok)" "/crash: 500 with Connection: close"
  check "$(body_has c '<h1 id="root-error">500 Internal Server Error</h1>' && body_has c 'id="root-layout"' && body_has c 'id="crashed"' && echo ok)" "/crash: root error.html, crashed, inside the root layout"
  id=$(body_id c)
  check "$([ -n "$id" ] && logged "$id" 500 GET /crash && echo ok)" "/crash: the log line has the page's id"
  check "$(grep -q 'gweb: worker 0 stopped' "$LOG" && echo ok)" "/crash: the supervisor logged the stop"
  check "$(! body_has c 'gw-dev-error' && echo ok)" "/crash: no detail in production"
  check "$(! body_has c 'index' && ! body_has c 'out of bounds' && echo ok)" "/crash: the abort text is not in the page"
  req home GET /
  check "$([ "$(status home)" = 200 ] && body_has home 'id="home"' && echo ok)" "the next request on a new connection succeeds (worker respawned)"

  # Several crashes in a row: the single worker keeps coming back.
  allok=ok
  for n in 1 2 3 4 5; do
    req loop GET /crash
    [ "$(status loop)" = 500 ] || allok=no
  done
  req home2 GET /
  check "$([ "$allok" = ok ] && [ "$(status home2)" = 200 ] && echo ok)" "five crashes in a row, then a normal page"

  # Nested error.html wins and renders inside the layouts at or above its own folder.
  req n GET /nested
  check "$([ "$(status n)" = 500 ] && has_header n 'connection: close' && echo ok)" "/nested crash: 500 with Connection: close"
  check "$(body_has n 'id="nested-error">nested: 500 Internal Server Error' && ! body_has n 'id="root-error"' && echo ok)" "/nested crash: the nested error.html, not the root one"
  check "$(body_has n 'id="nested-layout"' && body_has n 'id="root-layout"' && echo ok)" "/nested crash: inside nested/layout.html and the root layout"
  req nf GET /nested/fail
  check "$([ "$(status nf)" = 409 ] && body_has nf 'nested: 409 Conflict here.' && ! body_has nf 'id="root-error"' && echo ok)" "/nested/fail: 409 through the nested error.html"
  # A folder below it with no error.html of its own uses the nested one; a sibling uses the root one.
  req f2 GET /fail
  check "$(body_has f2 'id="root-error"' && echo ok)" "a sibling folder still uses the root error.html"

  # A crashing layout above the error file: attempt 2 renders the error.html bare.
  req s GET /shaky
  check "$([ "$(status s)" = 500 ] && body_has s 'id="root-error"' && ! body_has s 'id="shaky"' && echo ok)" "/shaky (its own layout crashes): the root error.html inside the root layout"
  req si GET /shaky/inner
  check "$([ "$(status si)" = 500 ] && has_header si 'connection: close' && echo ok)" "/shaky/inner: 500 with Connection: close"
  check "$(body_has si 'id="inner-error">inner 500' && ! body_has si 'id="root-layout"' && ! body_has si 'id="shaky"' && echo ok)" "/shaky/inner: its error.html's layout crashes, so attempt 2 sends it without layouts"
  req home3 GET /
  check "$([ "$(status home3)" = 200 ] && echo ok)" "after the layout crashes the server still answers"

  # A crashing error.html: the fixed plain-text 500, written by C.
  req b GET /brokenerr
  check "$([ "$(status b)" = 500 ] && has_header b 'connection: close' && has_header b 'content-type: text/plain' && echo ok)" "/brokenerr: plain-text 500 with Connection: close"
  check "$([ "$(cat "$WORK/b.b")" = '500 Internal Server Error' ] && echo ok)" "/brokenerr: the body is the fixed text"
  req bf GET /brokenerr/fail
  check "$([ "$(status bf)" = 500 ] && has_header bf 'content-type: text/plain' && [ "$(cat "$WORK/bf.b")" = '500 Internal Server Error' ] && echo ok)" "/brokenerr/fail: a crash while rendering a gweb::fail page (phase 1) also ends in the plain 500"
  req home4 GET /
  check "$([ "$(status home4)" = 200 ] && echo ok)" "after the plain 500 the server still answers"

  # Routes answer JSON.
  req ab GET /api/boom
  check "$([ "$(status ab)" = 500 ] && has_header ab 'content-type: application/json' && has_header ab 'connection: close' && echo ok)" "/api/boom (crash): 500, JSON, Connection: close"
  check "$(grep -qE '^\{"error":"Internal Server Error","id":"[0-9a-f]{16}"\}$' "$WORK/ab.b" && echo ok)" "/api/boom: {\"error\":\"Internal Server Error\",\"id\":\"<id>\"}"
  id=$(body_id ab)
  check "$([ -n "$id" ] && logged "$id" 500 GET /api/boom && echo ok)" "/api/boom: the log line has the reply's id"
  req af GET /api/fail
  check "$([ "$(status af)" = 429 ] && has_header af 'content-type: application/json' && echo ok)" "/api/fail: 429, JSON"
  check "$(grep -qE '^\{"error":"Slow down\.","id":"[0-9a-f]{16}"\}$' "$WORK/af.b" && echo ok)" "/api/fail: {\"error\":\"Slow down.\",\"id\":\"<id>\"}"
  check "$(! body_has af '<html' && ! body_has af 'root-layout' && echo ok)" "/api/fail: no HTML page"

  # D14: a page POST that takes res and ends the reply itself with gweb::done.
  TK=0123456789abcdef0123456789abcdef
  C="Cookie: gw_csrf=$TK"
  req lg GET /limit
  check "$([ "$(status lg)" = 200 ] && body_has lg 'id="limit"' && echo ok)" "GET /limit: the page renders"
  req lp POST /limit -H "$C" -d "_csrf=$TK"
  check "$([ "$(status lp)" = 429 ] && has_header lp 'retry-after: 30' && echo ok)" "POST /limit: 429 with Retry-After: 30 from the handler"
  check "$([ "$(cat "$WORK/lp.b")" = 'slow down' ] && echo ok)" "POST /limit: the body is exactly the handler's"
  check "$(! body_has lp '<html' && ! body_has lp 'root-layout' && ! body_has lp 'id="limit"' && ! body_has lp 'root-error' && echo ok)" "POST /limit: no layout, page or error markup"

  # gweb::fail from a page POST without res: error.html with the status.
  req tp POST /tries -H "$C" -d "_csrf=$TK"
  check "$([ "$(status tp)" = 429 ] && has_header tp 'content-type: text/html' && echo ok)" "POST /tries: 429, HTML"
  check "$(body_has tp '<h1 id="root-error">429 Too many tries.</h1>' && body_has tp 'id="root-layout"' && ! body_has tp 'id="tries"' && echo ok)" "POST /tries: error.html with 429 and the message, inside the layout, page not rendered"
  id=$(body_id tp)
  check "$([ -n "$id" ] && logged "$id" 429 POST /tries && echo ok)" "POST /tries: the log line has the page's id"

  # Ids differ between errors.
  req d1 GET /fail
  req d2 GET /fail
  check "$([ -n "$(body_id d1)" ] && [ "$(body_id d1)" != "$(body_id d2)" ] && echo ok)" "two errors have two ids"

  # A 404 from gweb::fail is not not-found.html; the unknown path is still the 404 page (no not-found.html here: plain).
  req nope GET /no/such/page
  check "$([ "$(status nope)" = 404 ] && echo ok)" "an unknown path is still 404"
  stop_server
fi

# 2. Dev: --dev-id adds gw-dev-error before the dev script.
if ! start_server --dev-id 7; then
  bad "the dev server did not answer on port $PORT"
else
  req dc GET /crash
  check "$([ "$(status dc)" = 500 ] && body_has dc '<script type="application/json" id="gw-dev-error">' && body_has dc '__gweb/id' && echo ok)" "dev /crash: gw-dev-error and the dev script"
  a=$(grep -bo 'id="gw-dev-error"' "$WORK/dc.b" | head -n 1 | cut -d: -f1)
  b=$(grep -bo '__gweb/id' "$WORK/dc.b" | head -n 1 | cut -d: -f1)
  check "$([ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && echo ok)" "dev /crash: gw-dev-error comes before the dev script"
  check "$(body_has dc 'GET /crash' && echo ok)" "dev /crash: the detail names the request"
  check "$(python3 -I -c '
import json, re, sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r"id=\"gw-dev-error\">(.*?)</script>", t, re.S)
d = json.loads(m.group(1))
sys.exit(0 if isinstance(d, str) and d.startswith("GET /crash") and len(d) <= 4096 and "<" not in m.group(1) else 1)
' "$WORK/dc.b" && echo ok)" "dev /crash: gw-dev-error is a JSON string, at most 4096 bytes, safe inside <script>"
  # E1: whether the abort text names a source location decides if lines are shown. Informational.
  if body_has dc 'app/crash/page.goose'; then echo "INFO dev /crash: source excerpt present (E1: why has a location)"
  else echo "INFO dev /crash: no source excerpt (E1: why has no path:line here); the page shows the abort text and request only"; fi
  req dn GET /nested
  check "$(body_has dn 'id="nested-error"' && body_has dn 'id="gw-dev-error"' && echo ok)" "dev /nested: the nested error.html and the detail"
  req df GET /fail
  check "$([ "$(status df)" = 503 ] && body_has df 'id="gw-dev-error"' && body_has df 'Down for maintenance.' && body_has df 'GET /fail' && echo ok)" "dev /fail: detail has the request and the message"
  req dj GET /api/boom
  check "$([ "$(status dj)" = 500 ] && ! body_has dj 'gw-dev-error' && echo ok)" "dev /api/boom: JSON has no detail script"
  req db GET /brokenerr
  check "$([ "$(status db)" = 500 ] && ! body_has db 'gw-dev-error' && echo ok)" "dev /brokenerr: the plain 500 has no detail"
  stop_server
fi

# 2b. Step 7: build-error excerpts. `gweb dev --once` (hidden) builds once, writes
# .gooseweb.dev/errors.txt with the excerpts and exits; a good site leaves it empty.
cp -R "$HERE/errors/site" "$WORK/bad"
rm -rf "$WORK/bad/.gooseweb"
mkdir -p "$WORK/bad/app/broken"
printf '%s\n' '<h1>one</h1>' '<p>two</p>' '<p>three</p>' '<p>{no_such_name}</p>' '<p>five</p>' '<p>six</p>' '<p>seven</p>' > "$WORK/bad/app/broken/page.html"
"$GWEB" -C "$WORK/bad" build > "$WORK/bad.plain" 2>&1
plain_rc=$?
"$GWEB" -C "$WORK/bad" dev --once > /dev/null 2>&1
dev_rc=$?
ET="$WORK/bad/.gooseweb.dev/errors.txt"
check "$([ "$plain_rc" != 0 ] && [ "$dev_rc" != 0 ] && echo ok)" "a type error in page.html fails build and dev --once"
check "$(grep -q '^app/broken/page.html:4:' "$ET" 2>/dev/null && echo ok)" "errors.txt has the path:line: error line"
check "$(grep -qF '>   4 | <p>{no_such_name}</p>' "$ET" 2>/dev/null && echo ok)" "errors.txt marks the error line with > and its number"
check "$(grep -qF '   2 | <p>two</p>' "$ET" 2>/dev/null && grep -qF '   3 | <p>three</p>' "$ET" && grep -qF '   5 | <p>five</p>' "$ET" && grep -qF '   6 | <p>six</p>' "$ET" && echo ok)" "errors.txt has 2 lines before and 2 after"
check "$(! grep -qF ' | <p>seven</p>' "$ET" 2>/dev/null && ! grep -qF ' | <h1>one</h1>' "$ET" 2>/dev/null && echo ok)" "errors.txt has no lines beyond the 2-line window"
check "$(! grep -qF ' | ' "$WORK/bad.plain" && echo ok)" "plain gweb build output has no excerpt"
rm -f "$WORK/bad/app/broken/page.html"
rmdir "$WORK/bad/app/broken"
"$GWEB" -C "$WORK/bad" dev --once > /dev/null 2>&1
check "$([ $? = 0 ] && [ ! -s "$ET" ] && echo ok)" "dev --once on a good site leaves errors.txt empty"

# 3. Informational: plaintext requests per second.
# BENCH_BASE=/path/to/server (built from the commit before step 5, with the same site) adds a "before" line.
# The ratio is printed, never checked: the design's 2% limit needs a quiet machine and a real load tool
# (wrk, hey); this stub is one curl process on keep-alive connections.
N=${BENCH_N:-5000}
bench() {
  python3 -I -c '
import subprocess, sys, time
exe, port, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
p = subprocess.Popen([exe, "--port", port, "--workers", "2"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    url = "http://127.0.0.1:%s/plain" % port
    for _ in range(40):
        time.sleep(0.25)
        if subprocess.call(["curl", "-s", "-o", "/dev/null", url]) == 0: break
    best = 0
    for _ in range(3):
        t = time.time()
        subprocess.call(["curl", "-s", "-o", "/dev/null", url + "?[1-%d]" % n])
        best = max(best, n / (time.time() - t))
    print("%.0f" % best)
finally:
    p.kill(); p.wait()
' "$1" "$PORT" "$N" 2>/dev/null
}
after=$(cd "$WORK/ok" && bench "$WORK/ok/.gooseweb/server")
echo "INFO plaintext (curl, $N requests, 2 workers): ${after:-n/a} requests/s with the in-flight copy"
if [ -n "${BENCH_BASE:-}" ] && [ -x "$BENCH_BASE" ]; then
  before=$(cd "$WORK/ok" && bench "$BENCH_BASE")
  echo "INFO plaintext before step 5: ${before:-n/a} requests/s"
  if [ -n "${before:-}" ] && [ -n "${after:-}" ]; then
    python3 -I -c 'import sys; b, a = float(sys.argv[1]), float(sys.argv[2]); print("INFO change: %.1f%% (stop-and-ask above 2%% slower)" % ((a - b) / b * 100))' "$before" "$after"
  fi
else
  echo "INFO set BENCH_BASE=/path/to/older/server to compare; not run"
fi

echo "errors.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
