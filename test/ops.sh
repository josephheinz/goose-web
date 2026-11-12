#!/bin/sh
# goose-web's operations suite (DESIGN-ADDENDUM-16, step B6).
#
#   GOOSE=/path/to/goose test/ops.sh          (PORT=3996 by default)
#
# test/ops/site has state, jobs (Bump, Tick on a 1 s schedule, Fail, Boom) and a /slow route. It is built once and
# started several times, always by its binary (not gweb start), so SIGUSR2 can re-exec it:
#
# 1. metrics + JSON log: health, ready, HEAD, /__gweb/metrics as Prometheus text with route labels and a nonzero
#    start time, JSON log keys, X-Request-Id echo and refusal, --probe, jobs (Bump, schedule, Fail with retries,
#    Boom aborting a runner), SIGTERM exits 0 and runs state::shutdown.
# 2. drain: no --metrics (404), text access line, --drain-delay-ms 1000: after SIGTERM /__gweb/ready is 503 and
#    enqueue is refused while a /slow request still gets 200; later connections fail; exit 0; the shutdown marker and
#    the "queued jobs dropped" line exist. --probe exits 1 once the server is gone.
# 3. a second SIGTERM exits at once, without the shutdown marker.
# 4. handoff: SIGUSR2 starts a new process (a new /token, the per-process random token of state::init) and the old one
#    exits, while a loop of requests sees only 200. A second SIGUSR2 with $OPS_DIR/fail_init present (the marker
#    state::init checks; listen_inherited unsets the handoff variables before init, so init cannot tell a handoff
#    child from a start) makes the child exit 1: the old process keeps serving and logs "handoff failed".
# 5. gweb new: Dockerfile and .dockerignore equal deploy/Dockerfile and deploy/dockerignore; the starter site (no
#    state, no jobs) builds, serves, labels its routes in the metrics and stops with SIGTERM.
# 6. Build errors: app/jobs.goose without fn run or without Job, and an app/__gweb folder, fail gweb build.
#
# Needs curl and python3, and gweb built beside this folder (goose build -o gweb cli/gweb.goose).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
PORT=${PORT:-3996}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-ops.XXXXXX")
PID=""
HAMMER=""
TK=0123456789abcdef0123456789abcdef
SERVER="$WORK/site/.gooseweb/server"
URL="http://127.0.0.1:$PORT"
cleanup() {
  [ -n "$HAMMER" ] && kill "$HAMMER" 2>/dev/null
  for p in $PID $(pgrep -f "$WORK/" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { if [ "$1" = ok ]; then ok; else bad "$2"; fi; }

req() {
  name=$1; method=$2; path=$3; shift 3
  curl -s -m 10 -X "$method" -D "$WORK/$name.h.raw" -o "$WORK/$name.b" -w '%{http_code}' "$@" "$URL$path" > "$WORK/$name.status"
  tr -d '\r' < "$WORK/$name.h.raw" | tr 'A-Z' 'a-z' > "$WORK/$name.h" 2>/dev/null
}
status() { cat "$WORK/$1.status"; }
has_header() { grep -q "^$2" "$WORK/$1.h"; }
body_has() { grep -qF -- "$2" "$WORK/$1.b"; }
post() { req "$1" POST "$2" -H "Cookie: gw_csrf=$TK" -H "X-CSRF-Token: $TK"; }
# poll TENTHS CMD...: runs CMD until it succeeds, up to TENTHS tenths of a second.
poll() {
  n=$1; shift; i=0
  while [ "$i" -lt "$n" ]; do
    if "$@"; then return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
count_of() { curl -s -m 5 "$URL/count" | sed -n 's/^count=\([0-9]*\) .*/\1/p'; }
ticks_of() { curl -s -m 5 "$URL/count" | sed -n 's/.* ticks=\([0-9]*\)$/\1/p'; }
metric() { curl -s -m 5 "$URL/__gweb/metrics" | awk -v n="$1" '$1 == n { print $2 }'; }
count_at_least() { [ "$(count_of)" -ge "$1" ] 2>/dev/null; }
log_lines() { grep -c -- "$2" "$WORK/$1.log"; }
log_at_least() { [ "$(log_lines "$1" "$2")" -ge "$3" ]; }
gone() { ! kill -0 "$1" 2>/dev/null; }
up() { curl -s -m 2 -o /dev/null "$URL/__gweb/ready"; }

# start NAME FLAGS...: starts the site's server in the background with its log in $WORK/NAME.log.
start() {
  name=$1; shift
  OPS_DIR="$WORK/ops" "$SERVER" --port "$PORT" "$@" > "$WORK/$name.log" 2>&1 &
  PID=$!
  if ! poll 100 up; then bad "$name: the server did not answer on port $PORT"; cat "$WORK/$name.log"; return 1; fi
  return 0
}
# stop_wait: after a signal, waits for PID and reports its exit status in $rc.
stop_wait() {
  rc=""
  if ! poll "$1" gone "$PID"; then rc=timeout; kill -9 "$PID" 2>/dev/null; fi
  wait "$PID" 2>/dev/null
  st=$?
  [ "${rc:-}" = timeout ] || rc=$st
  PID=""
}

mkdir -p "$WORK/ops"
cp -R "$HERE/ops/site" "$WORK/site"
if ! out=$("$GWEB" -C "$WORK/site" build 2>&1); then
  bad "gweb build of the site"; echo "$out"
  echo "ops: $pass passed, $((fail)) failed"
  exit 1
fi

# 1. metrics, JSON log, jobs.
if start s1 --metrics --log --log-format json --workers 2 --job-attempts 3; then
  req health GET /__gweb/health
  check "$([ "$(status health)" = 200 ] && body_has health ok && has_header health 'cache-control: no-store' && echo ok)" "health: 200 ok, no-store"
  req ready GET /__gweb/ready
  check "$([ "$(status ready)" = 200 ] && body_has ready ready && has_header ready 'cache-control: no-store' && echo ok)" "ready: 200 ready, no-store"
  req head HEAD /__gweb/health
  check "$([ "$(status head)" = 200 ] && [ ! -s "$WORK/head.b" ] && echo ok)" "HEAD /__gweb/health: 200, no body"
  req postready POST /__gweb/ready
  check "$([ "$(status postready)" != 200 ] && echo ok)" "POST /__gweb/ready is not answered as a probe"
  check "$("$SERVER" --probe --port "$PORT" && echo ok)" "--probe exits 0 while the server is up"

  req count GET /count
  check "$([ "$(status count)" = 200 ] && body_has count 'count=0' && echo ok)" "GET /count: 200, count=0"
  req id GET /count -H 'X-Request-Id: abc-1.2_Z'
  check "$(has_header id 'x-request-id: abc-1.2_z' && echo ok)" "a valid X-Request-Id is echoed"
  for bad_id in 'has space' 'semi;colon' "$(python3 -I -c 'print("a" * 65)')"; do
    req idbad GET /count -H "X-Request-Id: $bad_id"
    got=$(grep '^x-request-id: ' "$WORK/idbad.h" | sed 's/^x-request-id: //')
    check "$(printf '%s' "$got" | grep -Eq '^[0-9a-f]{16}$' && echo ok)" "an invalid X-Request-Id ('$bad_id') is replaced by 16 hex digits, got '$got'"
  done
  req id2 GET /count
  check "$(grep -Eq '^x-request-id: [0-9a-f]{16}$' "$WORK/id2.h" && echo ok)" "a request without X-Request-Id gets one"
  req page GET /
  req tok GET /token
  req nf GET /nothing-here

  # metrics
  req metrics GET /__gweb/metrics
  check "$([ "$(status metrics)" = 200 ] && has_header metrics 'content-type: text/plain' && echo ok)" "metrics: 200 text/plain"
  check "$(python3 -I "$HERE/c/promcheck.py" "$WORK/metrics.b" >/dev/null 2>&1 && echo ok)" "metrics parse as Prometheus text"
  for want in 'route="/count",method="GET",code="2xx"' 'route="/",method="GET",code="2xx"' 'route="/token",method="GET"' \
              'gweb_http_request_duration_seconds_bucket{route="/count"' '# TYPE gweb_http_connections_open gauge' \
              'gweb_build_info{version=' 'gweb_jobs_queued'; do
    check "$(body_has metrics "$want" && echo ok)" "metrics have '$want'"
  done
  check "$(! body_has metrics '__gweb' && echo ok)" "the health and metrics URLs are not counted"
  started=$(metric gweb_process_start_time_seconds)
  check "$(python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 1e9 else 1)' "${started:-0}" && echo ok)" "gweb_process_start_time_seconds is a recent epoch time, got '${started:-}'"

  # JSON log
  sleep 0.2
  verdict=$(python3 -I - "$WORK/s1.log" <<'PY'
import json, sys
need = {"ts", "level", "msg", "method", "target", "route", "status", "dur_us", "bytes", "worker", "request_id"}
reqs = 0
for n, line in enumerate(open(sys.argv[1]), 1):
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except ValueError:
        print("line %d is not JSON: %s" % (n, line[:80])); sys.exit(0)
    if "ts" not in o or "level" not in o or "msg" not in o:
        print("line %d lacks ts, level or msg" % n); sys.exit(0)
    if o["msg"] == "request":
        reqs += 1
        if not need <= set(o):
            print("request line %d lacks %s" % (n, sorted(need - set(o)))); sys.exit(0)
        if "__gweb" in o["target"] and o["method"] in ("GET", "HEAD"):
            print("a health or metrics request was logged"); sys.exit(0)
if reqs < 5:
    print("only %d request lines" % reqs); sys.exit(0)
print("ok")
PY
)
  check "$([ "$verdict" = ok ] && echo ok)" "the JSON log: $verdict"
  check "$(grep -q '"route":"/count"' "$WORK/s1.log" && grep -q '"route":"-"' "$WORK/s1.log" && echo ok)" "JSON log: route pattern, and - for no match"

  # jobs
  post enq1 /enqueue/bump
  check "$([ "$(status enq1)" = 202 ] && echo ok)" "POST /enqueue/bump: 202"
  check "$(poll 50 count_at_least 1 && echo ok)" "a Bump job raises the count"
  t0=$(ticks_of)
  sleep 3.2
  t1=$(ticks_of)
  check "$([ "${t1:-0}" -ge $(( ${t0:-0} + 2 )) ] && echo ok)" "the 1 s schedule raised ticks over 3 s ($t0 to $t1)"
  post enqx /enqueue/nope
  check "$([ "$(status enqx)" = 404 ] && echo ok)" "an unknown job kind: 404"

  post enq2 /enqueue/fail
  check "$(poll 60 log_at_least s1 'job attempt failed' 2 && echo ok)" "a Fail job is logged as a failed attempt and retried"
  check "$(poll 60 sh -c "[ \"\$(curl -s -m 5 $URL/__gweb/metrics | awk '\$1 == \"gweb_jobs_failed_total\" { print \$2 }')\" -ge 2 ] 2>/dev/null" && echo ok)" "gweb_jobs_failed_total rises"

  post enq3 /enqueue/boom
  check "$(poll 60 log_at_least s1 'job runner 0 aborted' 1 && echo ok)" "a Boom job aborts its runner and the supervisor logs 'aborted'"
  req alive GET /count
  check "$([ "$(status alive)" = 200 ] && echo ok)" "the server still answers after a job aborted"
  check "$(poll 80 log_at_least s1 'job runner 0 aborted' 2 && echo ok)" "the aborted job is tried again"
  before=$(count_of)
  post enq4 /enqueue/bump
  check "$(poll 100 count_at_least $(( ${before:-0} + 1 )) && echo ok)" "the runner restarted: a later Bump runs"

  # SIGTERM exits 0 and runs state::shutdown
  rm -f "$WORK/ops/shutdown"
  kill -TERM "$PID"
  stop_wait 100
  check "$([ "$rc" = 0 ] && echo ok)" "SIGTERM: exit status 0 (got $rc)"
  check "$([ -f "$WORK/ops/shutdown" ] && echo ok)" "SIGTERM: state::shutdown ran"
fi
check "$("$SERVER" --probe --port "$PORT"; [ $? = 1 ] && echo ok)" "--probe exits 1 when no server is up"

# 2. the drain.
rm -f "$WORK/ops/shutdown"
if start s2 --workers 2 --job-runners 0 --drain-delay-ms 1000 --drain-ms 5000 --log; then
  req nometrics GET /__gweb/metrics
  check "$([ "$(status nometrics)" = 404 ] && echo ok)" "/__gweb/metrics is 404 without --metrics"
  req t GET /count
  check "$(grep -Eq '^\[[0-9]+\] GET /count -> 200 OK [0-9]+us$' "$WORK/s2.log" && echo ok)" "text access line: [slot] METHOD target -> status Nus"
  post q1 /enqueue/bump
  check "$([ "$(status q1)" = 202 ] && echo ok)" "with no runners a job is accepted and waits"

  curl -s -m 10 -o "$WORK/slow.b" -w '%{http_code}' "$URL/slow" > "$WORK/slow.status" 2>/dev/null &
  slow=$!
  sleep 0.3
  kill -TERM "$PID"
  sleep 0.3
  req ready2 GET /__gweb/ready
  check "$([ "$(status ready2)" = 503 ] && body_has ready2 stopping && echo ok)" "after SIGTERM /__gweb/ready is 503 stopping while connections are still accepted"
  req health2 GET /__gweb/health
  check "$([ "$(status health2)" = 200 ] && echo ok)" "after SIGTERM /__gweb/health is still 200"
  post q2 /enqueue/bump
  check "$([ "$(status q2)" = 503 ]  && echo ok)" "after SIGTERM enqueue is refused (503)"
  wait "$slow"
  check "$([ "$(cat "$WORK/slow.status")" = 200 ] && grep -q 'slow done' "$WORK/slow.b" && echo ok)" "the /slow request in flight at SIGTERM completes with 200"
  late=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$URL/count" 2>/dev/null)
  check "$([ "$late" != 200 ] && echo ok)" "a connection after the delay is refused or not served (got '$late')"
  stop_wait 80
  check "$([ "$rc" = 0 ] && echo ok)" "the drained process exits 0 (got $rc)"
  check "$([ -f "$WORK/ops/shutdown" ] && echo ok)" "the drain ran state::shutdown"
  check "$(grep -q 'queued jobs dropped' "$WORK/s2.log" && echo ok)" "queued jobs dropped are logged"
fi
check "$("$SERVER" --probe --port "$PORT"; [ $? = 1 ] && echo ok)" "--probe exits 1 once the server has stopped"

# 3. a second SIGTERM.
rm -f "$WORK/ops/shutdown"
if start s3 --workers 1 --job-runners 0 --drain-delay-ms 10000; then
  kill -TERM "$PID"
  sleep 0.5
  check "$(kill -0 "$PID" 2>/dev/null && echo ok)" "one SIGTERM with a long --drain-delay-ms keeps the process running"
  kill -TERM "$PID"
  stop_wait 30
  check "$([ "$rc" = 130 ] && echo ok)" "a second SIGTERM exits at once with status 130 (got $rc)"
  check "$([ ! -f "$WORK/ops/shutdown" ] && echo ok)" "a second SIGTERM skips state::shutdown"
fi

# 4. the handoff.
if start s4 --workers 2 --no-schedule; then
  OLD=$PID
  tok1=$(curl -s -m 5 "$URL/token")
  check "$([ -n "$tok1" ] && echo ok)" "/token answers"
  rm -f "$WORK/hammer.codes" "$WORK/hammer.stop"
  (
    while [ ! -f "$WORK/hammer.stop" ]; do
      curl -s -m 10 -o /dev/null -w '%{http_code}\n' "$URL/count" >> "$WORK/hammer.codes" 2>/dev/null || echo "curl-failed" >> "$WORK/hammer.codes"
      sleep 0.02
    done
  ) &
  HAMMER=$!
  sleep 0.3
  kill -USR2 "$OLD"
  newtoken() { t=$(curl -s -m 5 "$URL/token"); [ -n "$t" ] && [ "$t" != "$tok1" ]; }
  check "$(poll 150 newtoken && echo ok)" "SIGUSR2: a new process answers (a new /token)"
  check "$(poll 150 gone "$OLD" && echo ok)" "SIGUSR2: the old process exits"
  sleep 0.5
  touch "$WORK/hammer.stop"
  wait "$HAMMER" 2>/dev/null
  HAMMER=""
  total=$(wc -l < "$WORK/hammer.codes" | tr -d ' ')
  failures=$(grep -vc '^200$' "$WORK/hammer.codes")
  check "$([ "$total" -ge 20 ] && [ "$failures" = 0 ] && echo ok)" "requests during the handoff: $total sent, $failures not 200"
  wait "$OLD" 2>/dev/null
  PID=""
  NEW=$(pgrep -f "$SERVER --port $PORT" | head -n 1)
  check "$([ -n "$NEW" ] && [ "$NEW" != "$OLD" ] && echo ok)" "the new process has its own pid"
  tok2=$(curl -s -m 5 "$URL/token")

  # a child whose init fails
  touch "$WORK/ops/fail_init"
  kill -USR2 "$NEW"
  sleep 2
  rm -f "$WORK/ops/fail_init"
  tok3=$(curl -s -m 5 "$URL/token")
  check "$([ -n "$tok3" ] && [ "$tok3" = "$tok2" ] && kill -0 "$NEW" 2>/dev/null && echo ok)" "a handoff child that fails init leaves the old process serving"
  check "$(grep -q 'handoff failed' "$WORK/s4.log" && echo ok)" "the failed handoff is logged"
  check "$(up && echo ok)" "the server is still up after the failed handoff"
  kill -TERM "$NEW"
  check "$(poll 100 gone "$NEW" && echo ok)" "SIGTERM stops the handed-off process"
fi

# 5. gweb new.
mkdir "$WORK/new"
if "$GWEB" -C "$WORK/new" new starter >/dev/null 2>&1; then
  check "$(cmp -s "$WORK/new/starter/Dockerfile" "$ROOT/deploy/Dockerfile" && echo ok)" "gweb new writes deploy/Dockerfile"
  check "$(cmp -s "$WORK/new/starter/.dockerignore" "$ROOT/deploy/dockerignore" && echo ok)" "gweb new writes deploy/dockerignore as .dockerignore"
  if out=$("$GWEB" -C "$WORK/new/starter" build 2>&1); then
    "$WORK/new/starter/.gooseweb/server" --port "$PORT" --metrics --workers 1 > "$WORK/starter.log" 2>&1 &
    PID=$!
    if poll 100 up; then
      req sp GET /
      req sh GET /hello/goose
      req sm GET /__gweb/metrics
      check "$([ "$(status sp)" = 200 ] && [ "$(status sh)" = 200 ] && echo ok)" "the starter site serves / and /hello/goose"
      check "$(body_has sm 'route="/hello/[name]",method="GET",code="2xx"' && body_has sm 'route="/",method="GET",code="2xx"' && echo ok)" "the starter's metrics carry the route labels"
      started=$(awk '$1 == "gweb_process_start_time_seconds" { print $2 }' "$WORK/sm.b")
      check "$(python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 1e9 else 1)' "${started:-0}" && echo ok)" "the starter's process start time is nonzero"
      kill -TERM "$PID"
      stop_wait 50
      check "$([ "$rc" = 0 ] && echo ok)" "the starter site exits 0 on SIGTERM (got $rc)"
    else
      bad "the starter site did not answer"; cat "$WORK/starter.log"
    fi
  else
    bad "gweb build of the starter site"; echo "$out"
  fi
else
  bad "gweb new"
fi

# 6. build errors.
expect_fail() {
  msg=$1; where=$2
  rm -rf "$WORK/f"
  cp -R "$HERE/ops/site" "$WORK/f"
  shift 2
  "$@"
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
no_run() { sed 's/^fn run(/fn runx(/' "$HERE/ops/site/app/jobs.goose" > "$WORK/f/app/jobs.goose"; }
no_job() { sed 's/^enum Job /enum Jobx /' "$HERE/ops/site/app/jobs.goose" > "$WORK/f/app/jobs.goose"; }
reserved() { mkdir -p "$WORK/f/app/__gweb"; echo x > "$WORK/f/app/__gweb/page.html"; }
reserved_deep() { mkdir -p "$WORK/f/app/count/__gweb"; echo x > "$WORK/f/app/count/__gweb/page.html"; }
nested_jobs() { mkdir -p "$WORK/f/app/count"; cp "$HERE/ops/site/app/jobs.goose" "$WORK/f/app/count/jobs.goose"; }
expect_fail "jobs.goose needs fn run(job: const Job&, ctx: web::Ctx&) -> bool" app/jobs.goose no_run
expect_fail "jobs.goose needs a type named Job" app/jobs.goose no_job
expect_fail "__gweb is reserved for the health, readiness and metrics URLs; rename this folder" app/__gweb reserved
expect_fail "__gweb is reserved for the health, readiness and metrics URLs; rename this folder" app/count/__gweb reserved_deep
expect_fail "jobs.goose belongs in app/ only" app/count/jobs.goose nested_jobs

echo "ops: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
