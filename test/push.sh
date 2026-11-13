#!/bin/sh
# gweb's streaming, SSE and WebSocket suite (DESIGN-ADDENDUM-15, sections 6 and 7).
#
#   GOOSE=/path/to/goose test/push.sh
#
# 1. test/push/site is built and started. curl --raw shows the chunks of a streamed route; two curl -N clients
#    on /events receive a publish made by a POST; a node WebSocket client (test/push/ws_client.mjs) gets its message
#    echoed by app/socket.goose and then a publish; a foreign Origin gets 403 and Sec-WebSocket-Version 8 gets 426.
#
# Needs curl and node, and gweb built beside this folder (goose build -o gweb cli/gweb.goose). The site needs a goose-net
# with net::Hub (its arch/delivery branch): set GWEB_NET to that checkout; by default the sibling worktree is used if it exists.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
PORT=${PORT:-3997}
if [ -z "${GWEB_NET:-}" ]; then
  cand="$ROOT/../../../goose-net/.worktrees/delivery"
  if [ -f "$cand/hub.goose" ]; then GWEB_NET=$(cd "$cand" && pwd); export GWEB_NET; fi
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-push.XXXXXX")
PIDS=""
PID=""
cleanup() {
  for p in $PIDS $PID; do kill "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { if [ "$1" = ok ]; then ok; else bad "$2"; fi; }

URL="http://127.0.0.1:$PORT"
# wait_for FILE PATTERN: up to 5 s for PATTERN to appear in FILE.
wait_for() {
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
    grep -q "$2" "$1" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

cp -R "$HERE/push/site" "$WORK/site"
if out=$("$GWEB" -C "$WORK/site" build 2>&1); then
  "$WORK/site/.gweb/server" --port "$PORT" --workers 2 >/dev/null 2>&1 &
  PID=$!
  up=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    if curl -s -o /dev/null "$URL/"; then up=1; break; fi
  done
  if [ -z "$up" ]; then
    bad "the server did not answer on port $PORT"
  else
    # Streaming: the raw bytes are chunked, a decoding client sees the text, HEAD gets the head, the connection is reused.
    curl -s --raw -D "$WORK/s.h" -o "$WORK/s.raw" "$URL/export"
    printf '4\r\none\n\r\n4\r\ntwo\n\r\n6\r\nthree\n\r\n0\r\n\r\n' > "$WORK/s.want"
    check "$(grep -qi '^transfer-encoding: chunked' "$WORK/s.h" && cmp -s "$WORK/s.raw" "$WORK/s.want" && echo ok)" "/export: Transfer-Encoding: chunked and three chunks, then the zero chunk"
    curl -s "$URL/export" > "$WORK/s.plain"
    check "$([ "$(cat "$WORK/s.plain")" = "$(printf 'one\ntwo\nthree')" ] && echo ok)" "/export decoded: one, two, three"
    curl -s -I -o "$WORK/s.head" -w '%{http_code}' --max-time 5 "$URL/export" > "$WORK/s.hs"
    check "$([ "$(cat "$WORK/s.hs")" = 200 ] && echo ok)" "HEAD /export: 200 and no hang"
    curl -s "$URL/export" "$URL/count" > "$WORK/s.two"
    check "$(grep -q 'three' "$WORK/s.two" && grep -q 'news=0' "$WORK/s.two" && echo ok)" "a streamed reply leaves the connection usable for the next request"

    # SSE: two subscribers, one POST.
    for n in 1 2; do
      curl -sN -D "$WORK/e$n.h" "$URL/events" > "$WORK/e$n.b" &
      PIDS="$PIDS $!"
    done
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      curl -s "$URL/count" > "$WORK/count"
      grep -q 'news=2' "$WORK/count" && break
      sleep 0.2
    done
    check "$(grep -q 'news=2' "$WORK/count" && echo ok)" "/count shows two subscribers on news"
    check "$(wait_for "$WORK/e1.h" 'X-Accel-Buffering' && grep -qi '^content-type: text/event-stream' "$WORK/e1.h" \
      && grep -qi '^cache-control: no-store' "$WORK/e1.h" && grep -qi '^x-accel-buffering: no' "$WORK/e1.h" && echo ok)" "/events: event-stream, no-store, X-Accel-Buffering: no"
    curl -s -X POST -d 'hello' "$URL/publish" > "$WORK/pub"
    check "$(wait_for "$WORK/e1.b" 'data: hello' && wait_for "$WORK/e2.b" 'data: hello' && echo ok)" "a POST that publishes reaches both curl -N clients"

    # WebSocket.
    node "$HERE/push/ws_client.mjs" "$PORT" /ws --chat > "$WORK/w.out" 2>&1 &
    WPID=$!
    PIDS="$PIDS $WPID"
    check "$(wait_for "$WORK/w.out" '^ready' && grep -q '^status 101' "$WORK/w.out" && grep -q '^accept ok' "$WORK/w.out" \
      && grep -q '^echo echo:ping1' "$WORK/w.out" && echo ok)" "WebSocket: 101, the right accept key, and the message echoed by app/socket.goose"
    curl -s -X POST -d 'bcast' "$URL/publish" > "$WORK/pub"
    check "$(wait_for "$WORK/w.out" '^done' && grep -q '^publish bcast' "$WORK/w.out" && echo ok)" "the WebSocket client receives the publish"
    wait "$WPID" 2>/dev/null

    node "$HERE/push/ws_client.mjs" "$PORT" /ws --origin http://evil.example > "$WORK/o1.out" 2>&1
    check "$(grep -q '^status 403' "$WORK/o1.out" && echo ok)" "a foreign Origin: 403"
    node "$HERE/push/ws_client.mjs" "$PORT" /ws --origin "http://127.0.0.1:$PORT" > "$WORK/o2.out" 2>&1
    check "$(grep -q '^status 101' "$WORK/o2.out" && echo ok)" "Origin equal to Host: 101"
    node "$HERE/push/ws_client.mjs" "$PORT" /wsallow --origin http://good.example > "$WORK/o3.out" 2>&1
    check "$(grep -q '^status 101' "$WORK/o3.out" && echo ok)" "Origin equal to allow_origin: 101"
    node "$HERE/push/ws_client.mjs" "$PORT" /wsallow --origin http://evil.example > "$WORK/o4.out" 2>&1
    check "$(grep -q '^status 403' "$WORK/o4.out" && echo ok)" "another Origin with allow_origin set: 403"
    node "$HERE/push/ws_client.mjs" "$PORT" /ws --version 8 > "$WORK/v.out" 2>&1
    check "$(grep -q '^status 426' "$WORK/v.out" && grep -q '^version 13' "$WORK/v.out" && echo ok)" "Sec-WebSocket-Version 8: 426 with Sec-WebSocket-Version: 13"
    curl -s -o "$WORK/plain.b" -w '%{http_code}' "$URL/ws" > "$WORK/plain.s"
    check "$([ "$(cat "$WORK/plain.s")" = 426 ] && echo ok)" "a plain GET to a WebSocket route: 426"
  fi
  kill "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null
  PID=""
else
  bad "gweb build of the site"; echo "$out"
fi

echo "push.sh: $pass of $((pass + fail)) checks passed"
[ "$fail" -eq 0 ]
