#!/bin/sh
# jobs::every_local (1.1): a schedule that still fires under --no-schedule.
#
#   GOOSE=/path/to/goose test/everylocal.sh
#
# test/everylocal/app registers jobs::every (plain) and jobs::every_local (local), both every 200 ms.
# 1. With --no-schedule, local counts up and plain stays 0.
# 2. Without it, both count up.
# 3. The same name in every and every_local is refused: the server exits 1 and says why.
#
# Needs curl and gweb built beside this folder. Polls with time limits.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
PORT=${PORT:-4023}
if [ ! -x "$GWEB" ]; then
  echo "everylocal.sh: $GWEB is missing; build it first: goose build -o gweb cli/gweb.goose"
  exit 1
fi
goose=${GOOSE:-}
[ -z "$goose" ] && goose=$(command -v goose 2>/dev/null || true)
if [ -z "$goose" ]; then echo "everylocal.sh: SKIP, no goose compiler (set GOOSE or put goose on PATH)"; exit 0; fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-everylocal.XXXXXX")
PID=""
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  rm -rf "${WORK:?}"
}
trap cleanup EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { if [ "$1" = ok ]; then ok; else bad "$2"; fi; }
show() { echo "$1" | sed 's/^/    /'; }

cp -R "$HERE/everylocal/app" "$WORK/app"
if ! out=$("$GWEB" -C "$WORK/app" build 2>&1); then bad "gweb build"; show "$out"; echo "everylocal.sh: $pass of $((pass + fail)) checks passed"; exit 1; fi
SERVER="$WORK/app/.gweb/server"
URL="http://127.0.0.1:$PORT"

# counts_ok KIND MIN: the field KIND is at least MIN.
field() { curl -s -m 2 "$URL/counts" | sed -n "s/.*\"$1\":\\([0-9]*\\).*/\\1/p"; }
local_at_least() { v=$(field local); [ -n "$v" ] && [ "$v" -ge "$1" ]; }
plain_at_least() { v=$(field plain); [ -n "$v" ] && [ "$v" -ge "$1" ]; }
# poll TRIES CMD...: up to TRIES tries, 0.1 s apart.
poll() {
  n=$1; shift
  while [ "$n" -gt 0 ]; do
    if "$@"; then return 0; fi
    sleep 0.1
    n=$((n - 1))
  done
  return 1
}
stop_server() {
  [ -z "$PID" ] && return
  kill -TERM "$PID" 2>/dev/null
  n=0
  while kill -0 "$PID" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
  case "$(ps -o stat= -p "$PID" 2>/dev/null | tr -d ' ')" in Z*) bad "the server is a zombie" ;; esac
  wait "$PID" 2>/dev/null
  PID=""
}

# 1. --no-schedule
(cd "$WORK/app" && exec "$SERVER" --port "$PORT" --workers 1 --no-schedule >"$WORK/s1.log" 2>&1) &
PID=$!
check "$(poll 150 local_at_least 3 && echo ok)" "--no-schedule: every_local fires"
sleep 1
check "$([ "$(field plain)" = 0 ] && echo ok)" "--no-schedule: every does not (plain is $(field plain))"
stop_server

# 2. Without it.
(cd "$WORK/app" && exec "$SERVER" --port "$PORT" --workers 1 >"$WORK/s2.log" 2>&1) &
PID=$!
check "$(poll 150 local_at_least 3 && poll 150 plain_at_least 3 && echo ok)" "default: both fire"
stop_server

# 3. A duplicate name is refused.
sed 's/"local", 200/"plain", 200/' "$HERE/everylocal/app/app/jobs.goose" > "$WORK/app/app/jobs.goose"
if out=$("$GWEB" -C "$WORK/app" build 2>&1); then
  (cd "$WORK/app" && exec "$SERVER" --port "$PORT" --workers 1 >"$WORK/s3.log" 2>&1) &
  PID=$!
  n=0
  while kill -0 "$PID" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
  wait "$PID" 2>/dev/null
  rc=$?
  PID=""
  check "$([ "$rc" = 1 ] && echo ok)" "a duplicate name between every and every_local exits 1 (got $rc)"
  check "$(grep -q 'schedule "plain": duplicate or invalid name' "$WORK/s3.log" && echo ok)" "and says why"
else bad "gweb build of the duplicate"; show "$out"; fi

echo "everylocal.sh: $pass of $((pass + fail)) checks passed"
[ "$fail" -eq 0 ]
