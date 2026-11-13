#!/bin/sh
# gweb's config and CLI suite (v1.0): one rule for flags and GWEB_* variables, the dev bind address, and --help.
#
#   GOOSE=/path/to/goose test/config.sh
#
# 1. gweb --help, help, -h and <command> --help print usage on stdout and exit 0; --version is version; a bad command is 2.
# 2. The server: every invalid variable and flag exits 2 with a message that names it; valid ones are accepted
#    (--probe exits 1 because nothing listens, never 2); PORT and GWEB_PORT start the server; --help exits 0.
# 3. The bind address: the server binds 0.0.0.0 and gweb dev binds 127.0.0.1, unless --host, GWEB_HOST or a .env file says
#    otherwise. The startup line names the address. gweb dev is started for real and its processes are stopped after.
# 4. gweb semver-cmp: the version compare that gweb.package checks use.
#
# Needs curl, and gweb built beside this folder (goose build -o gweb cli/gweb.goose).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
PORT=${PORT:-4010}
if [ ! -x "$GWEB" ]; then echo "config.sh: $GWEB is missing; build it first: goose build -o gweb cli/gweb.goose" >&2; exit 2; fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-config.XXXXXX")
PIDS=""
cleanup() {
  for p in $PIDS; do kill_tree "$p"; done
  rm -rf "$WORK"
}
# Stops a process and everything below it (gweb dev starts a shell, which starts the server).
kill_tree() {
  for c in $(ps -A -o pid= -o ppid= 2>/dev/null | awk -v p="$1" '$2 == p { print $1 }'); do kill_tree "$c"; done
  kill "$1" 2>/dev/null
}
trap cleanup EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { if [ "$1" = ok ]; then ok; else bad "$2"; fi; }
show() { echo "$1" | sed 's/^/    /'; }

# poll SECONDS CMD...: runs CMD until it succeeds, up to SECONDS seconds, however slow the machine is.
poll() {
  deadline=$(( $(date +%s) + $1 )); shift
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if "$@"; then return 0; fi
    sleep 0.2
  done
  return 1
}
# alive PID: running and not a zombie (a reaped-but-unwaited process passes kill -0 under dash).
alive() { kill -0 "$1" 2>/dev/null && case "$(ps -o stat= -p "$1" 2>/dev/null)" in ''|Z*) return 1 ;; esac; }

# 1. The command line.
out=$("$GWEB" --help 2>"$WORK/err"); rc=$?
check "$([ "$rc" = 0 ] && [ ! -s "$WORK/err" ] && printf '%s\n' "$out" | grep -q '^usage: gweb' && echo ok)" "gweb --help: usage on stdout, exit 0, nothing on stderr"
for flag in help -h "build --help" "start -h" "dev --help" "new --help" "test --help" "check -h" "lsp --help" "export --help" "gen --help" "routes --help" "version --help"; do
  o=$("$GWEB" $flag 2>"$WORK/err"); rc=$?
  check "$([ "$rc" = 0 ] && [ ! -s "$WORK/err" ] && [ "$o" = "$out" ] && echo ok)" "gweb $flag: the same usage on stdout, exit 0"
done
[ -e "$WORK/--help" ] && bad "gweb new --help made a folder"
for cmd in new gen build start dev export routes test check lsp version help; do
  check "$(printf '%s\n' "$out" | grep -q "^  $cmd[ \[]" && echo ok)" "the usage lists $cmd"
done
check "$(! printf '%s\n' "$out" | grep -q 'lsp-gen\|test-css\|semver-cmp' && echo ok)" "the usage hides lsp-gen, test-css and semver-cmp"
check "$(printf '%s\n' "$out" | grep -q -- '--access-log' && printf '%s\n' "$out" | grep -q -- '--no-schedule' && echo ok)" "the usage names the server flags"
check "$([ "$("$GWEB" --version)" = "$("$GWEB" version)" ] && echo ok)" "gweb --version is gweb version"
check "$([ "$("$GWEB" version | sed -n 1p)" = "gweb $(tr -d '[:space:]' < "$ROOT/VERSION")" ] && echo ok)" "gweb version starts with the version"
"$GWEB" frobnicate >"$WORK/out" 2>"$WORK/err"; rc=$?
check "$([ "$rc" = 2 ] && grep -q 'unknown command: frobnicate' "$WORK/err" && grep -q '^usage:' "$WORK/err" && [ ! -s "$WORK/out" ] && echo ok)" "an unknown command: exit 2, the reason and the usage on stderr"
"$GWEB" >"$WORK/out" 2>"$WORK/err"; rc=$?
check "$([ "$rc" = 2 ] && grep -q '^usage:' "$WORK/err" && echo ok)" "no command: exit 2, usage on stderr"

# 4. The version compare.
cmp() { "$GWEB" semver-cmp "$1" "$2" 2>/dev/null; }
check "$([ "$(cmp 0.10 0.7)" = 1 ] && [ "$(cmp 0.7 0.10)" = -1 ] && echo ok)" "semver: 0.10 is above 0.7 (numbers, not text)"
check "$([ "$(cmp 1.0 1.0.0)" = 0 ] && [ "$(cmp 1.0.0 1.0)" = 0 ] && [ "$(cmp 1.2 1.2.0)" = 0 ] && echo ok)" "semver: 1.0 is 1.0.0"
check "$([ "$(cmp 1.0.1 1.0)" = 1 ] && [ "$(cmp 1.0 1.0.1)" = -1 ] && [ "$(cmp 2.0 1.99.99)" = 1 ] && echo ok)" "semver: patch and major"
check "$([ "$(cmp 1.0.0-rc1 1.0.0)" = -1 ] && [ "$(cmp 1.0.0 1.0.0-rc1)" = 1 ] && [ "$(cmp 1.0-rc1 1.0.0-rc1)" = 0 ] && echo ok)" "semver: a prerelease is below its release"
check "$([ "$(cmp 1.0.0-rc.2 1.0.0-rc.10)" = -1 ] && [ "$(cmp 1.0.0-alpha 1.0.0-beta)" = -1 ] && [ "$(cmp 1.0.0-1 1.0.0-alpha)" = -1 ] && [ "$(cmp 1.0.0-rc 1.0.0-rc.1)" = -1 ] && echo ok)" "semver: prerelease identifiers compare one by one"
check "$([ "$(cmp 0.7.0 0.7.0)" = 0 ] && [ "$(cmp 1.3.2 1.0)" = 1 ] && echo ok)" "semver: a package asking for 1.0 accepts 1.3.2"
for bad_version in 1 1.x a.b 1.2.3.4 1..2 -1.0 1.0.0-; do
  "$GWEB" semver-cmp "$bad_version" 1.0 >/dev/null 2>&1; rc=$?
  check "$([ "$rc" = 2 ] && echo ok)" "semver: '$bad_version' is refused"
done

# 2. The server. One build, many starts.
"$GWEB" -C "$WORK" new site >/dev/null 2>&1
if ! out=$("$GWEB" -C "$WORK/site" build 2>&1); then
  bad "gweb build of the starter site"; show "$out"
  echo "config.sh: $pass of $((pass + fail)) checks passed"
  exit 1
fi
SERVER="$WORK/site/.gweb/server"
run() { (cd "$WORK/site" && "$@" 2>&1); }

out=$(run "$SERVER" --help); rc=$?
check "$([ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q -- '--max-body N' && printf '%s\n' "$out" | grep -q 'GWEB_' && echo ok)" "the server --help: the flags and the variables, exit 0"
out=$(run "$SERVER" -h); rc=$?
check "$([ "$rc" = 0 ] && echo ok)" "the server -h: exit 0"

# refused ENV=VALUE ...: the server exits 2 and the output names the variable and the value.
refused() {
  want=$1; shift
  out=$(cd "$WORK/site" && env "$@" "$SERVER" --probe 2>&1); rc=$?
  if [ "$rc" = 2 ]; then
    case "$out" in
      *"$want"*) ok ;;
      *) bad "$*: wanted '$want', got:"; show "$out" ;;
    esac
  else
    bad "$*: wanted exit 2, got $rc"; show "$out"
  fi
}
# accepted ENV=VALUE ...: the configuration passes; --probe then fails to reach anything and exits 1 (never 2).
accepted() {
  out=$(cd "$WORK/site" && env "$@" "$SERVER" --port 1 --probe 2>&1); rc=$?
  if [ "$rc" = 1 ]; then ok; else bad "$*: wanted the configuration accepted (exit 1), got $rc"; show "$out"; fi
}

refused 'GWEB_PORT=abc: must be a whole number from 1 to 65535' GWEB_PORT=abc
refused 'GWEB_PORT=0: must be a whole number from 1 to 65535' GWEB_PORT=0
refused 'GWEB_PORT=65536: must be a whole number from 1 to 65535' GWEB_PORT=65536
refused 'PORT=abc: must be a whole number from 1 to 65535' PORT=abc
refused 'GWEB_WORKERS=0: must be a whole number, 1 or more' GWEB_WORKERS=0
refused 'GWEB_WORKERS=many: ' GWEB_WORKERS=many
refused 'GWEB_IDLE_MS=-1: must be a whole number, 0 or more' GWEB_IDLE_MS=-1
refused 'GWEB_MAX_BODY=-1: must be a whole number, 1 or more' GWEB_MAX_BODY=-1
refused 'GWEB_MAX_BODY=lots: ' GWEB_MAX_BODY=lots
refused 'GWEB_MAX_UPLOAD=0: ' GWEB_MAX_UPLOAD=0
refused 'GWEB_MAX_UPLOAD_PARTS=0: ' GWEB_MAX_UPLOAD_PARTS=0
refused 'GWEB_MAX_UPLOAD_FILES=17: must be a whole number from 1 to 16' GWEB_MAX_UPLOAD_FILES=17
refused 'GWEB_MAX_UPLOAD_TEXT=-5: ' GWEB_MAX_UPLOAD_TEXT=-5
refused 'GWEB_DRAIN_MS=-1: ' GWEB_DRAIN_MS=-1
refused 'GWEB_DRAIN_DELAY_MS=x: ' GWEB_DRAIN_DELAY_MS=x
refused 'GWEB_JOB_RUNNERS=-1: ' GWEB_JOB_RUNNERS=-1
refused 'GWEB_JOB_QUEUE=0: ' GWEB_JOB_QUEUE=0
refused 'GWEB_JOB_ATTEMPTS=0: ' GWEB_JOB_ATTEMPTS=0
refused 'GWEB_SESSION_IDLE=0: ' GWEB_SESSION_IDLE=0
refused 'GWEB_SESSION_MAX=soon: ' GWEB_SESSION_MAX=soon
refused 'GWEB_HSTS=-1: ' GWEB_HSTS=-1
refused 'GWEB_METRICS=maybe: must be 1, 0, true, false, yes, no, on or off' GWEB_METRICS=maybe
refused 'GWEB_ACCESS_LOG=2: ' GWEB_ACCESS_LOG=2
refused 'GWEB_TRUST_PROXY=perhaps: ' GWEB_TRUST_PROXY=perhaps
refused 'GWEB_SECURITY_HEADERS=nope: ' GWEB_SECURITY_HEADERS=nope
refused 'GWEB_SCHEDULE=2: ' GWEB_SCHEDULE=2
refused 'GWEB_CSP=sometimes: must be 1, 0 or report-only' GWEB_CSP=sometimes
refused 'GWEB_LOG_LEVEL=loud: must be debug, info, warn or error' GWEB_LOG_LEVEL=loud
refused 'GWEB_LOG_FORMAT=xml: must be text or json' GWEB_LOG_FORMAT=xml
refused 'GWEB_SECRET: key 1 is shorter than 32 bytes' GWEB_SECRET=short
refused 'GWEB_ENV: invalid name' GWEB_ENV='bad name'
refused 'WEB_SECRET is now GWEB_SECRET' WEB_SECRET=x
# A bad value is an error even when a flag would override it: the mistake is in the environment.
refused 'GWEB_PORT=abc' GWEB_PORT=abc
out=$(run "$SERVER" --port 70000 --probe); rc=$?
check "$([ "$rc" = 2 ] && printf '%s' "$out" | grep -q -- '--port 70000: must be a whole number from 1 to 65535' && echo ok)" "--port 70000: exit 2, names the flag and value"
for args in "--port 0" "--port=-1" "--port x" "--idle-ms -1" "--max-body -1" "--max-body 0" "--workers 0" "--hsts -2" "--log-level loud" "--log-format xml" "--csp=sometimes" "--metrics=maybe" "--max-upload-files 99"; do
  out=$(cd "$WORK/site" && "$SERVER" $args --probe 2>&1); rc=$?
  flagname=$(printf '%s' "$args" | sed 's/[ =].*//')
  check "$([ "$rc" = 2 ] && printf '%s' "$out" | grep -qF -- "gweb: $flagname" && echo ok)" "$args: exit 2 and the message names $flagname"
done
# The message is true: unknown, incomplete and stray are different things.
out=$(run "$SERVER" --frobnicate --probe); rc=$?
check "$([ "$rc" = 2 ] && printf '%s' "$out" | grep -qF 'unknown flag: --frobnicate' && echo ok)" "an unknown flag says unknown flag"
out=$(run "$SERVER" --port); rc=$?
check "$([ "$rc" = 2 ] && printf '%s' "$out" | grep -qF -- '--port needs a value' && ! printf '%s' "$out" | grep -qF 'unknown' && echo ok)" "a flag with no value says it needs one, not unknown"
out=$(run "$SERVER" stray); rc=$?
check "$([ "$rc" = 2 ] && printf '%s' "$out" | grep -qF 'unexpected argument: stray' && echo ok)" "a stray word is an unexpected argument"
out=$(run "$SERVER" --log --probe); rc=$?
check "$([ "$rc" = 2 ] && printf '%s' "$out" | grep -qF -- '--log is now --access-log' && echo ok)" "--log names its replacement"

# Valid values, every spelling of a boolean, and empty variables (unset).
for w in 1 0 true false yes no on off TRUE Off; do accepted GWEB_METRICS=$w; done
accepted GWEB_PORT= GWEB_WORKERS= GWEB_MAX_BODY= GWEB_METRICS=
accepted GWEB_PORT=8080 PORT=notused
accepted GWEB_CSP=report-only
accepted GWEB_CSP=on GWEB_TRUST_PROXY=yes GWEB_SECURITY_HEADERS=off GWEB_SCHEDULE=0 GWEB_ACCESS_LOG=1
accepted GWEB_IDLE_MS=0 GWEB_MAX_UPLOAD_FILES=16 GWEB_HSTS=0 GWEB_LOG_LEVEL=debug GWEB_LOG_FORMAT=json
accepted GWEB_SECRET=0123456789abcdef0123456789abcdef
out=$(cd "$WORK/site" && "$SERVER" --port 1 --no-schedule --no-metrics --trust-proxy --no-security-headers --access-log --csp=off --probe 2>&1); rc=$?
check "$([ "$rc" = 1 ] && echo ok)" "the boolean flags in their three forms are accepted"
# A flag beats the variable.
out=$(cd "$WORK/site" && env GWEB_WORKERS=0 "$SERVER" --workers 1 --port 1 --probe 2>&1); rc=$?
check "$([ "$rc" = 2 ] && echo ok)" "a bad variable still stops the server when a flag would override it"

# PORT and GWEB_PORT start the server; GWEB_PORT wins; a flag wins over both.
started() {   # started NAME ENV... -- ARGS...: starts the server, waits for the startup line, stops it
  name=$1; shift
  envs=""
  while [ "$1" != "--" ]; do envs="$envs $1"; shift; done
  shift
  (cd "$WORK/site" && exec env $envs "$SERVER" "$@" >"$WORK/$name.log" 2>&1) &
  SPID=$!
  PIDS="$PIDS $SPID"
  poll 60 grep -q 'gweb: http://' "$WORK/$name.log"
}
stop_server() { kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null; }
if started portenv PORT=$PORT -- --workers 1; then
  check "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" | grep -q 200 && grep -q ":$PORT " "$WORK/portenv.log" && echo ok)" "PORT starts the server on that port"
else bad "PORT: the server did not start"; show "$(cat "$WORK/portenv.log")"; fi
stop_server
P2=$((PORT + 1))
if started gport PORT=1 GWEB_PORT=$P2 -- --workers 1; then
  check "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$P2/" | grep -q 200 && echo ok)" "GWEB_PORT beats PORT"
else bad "GWEB_PORT: the server did not start"; show "$(cat "$WORK/gport.log")"; fi
stop_server
if started fport GWEB_PORT=1 -- --workers 1 "--port=$PORT"; then
  check "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" | grep -q 200 && echo ok)" "--port=N beats GWEB_PORT"
else bad "--port=N: the server did not start"; show "$(cat "$WORK/fport.log")"; fi
stop_server

# 3. The bind address.
if started bind0 -- --workers 1 --port "$PORT"; then
  check "$(grep -q "gweb: http://0.0.0.0:$PORT " "$WORK/bind0.log" && echo ok)" "the server binds 0.0.0.0 by default (containers need it)"
else bad "the default server did not start"; show "$(cat "$WORK/bind0.log")"; fi
stop_server
if started bind1 -- --workers 1 --port "$PORT" --host 127.0.0.1; then
  check "$(grep -q "gweb: http://127.0.0.1:$PORT " "$WORK/bind1.log" && echo ok)" "--host 127.0.0.1 binds it"
else bad "--host server did not start"; show "$(cat "$WORK/bind1.log")"; fi
stop_server
# The server under --dev-id (what gweb dev starts) takes the dev defaults, and the flag and variable still win.
if started dev0 -- --dev-id 1 --port "$PORT"; then
  check "$(grep -q "gweb: http://127.0.0.1:$PORT (2 workers)" "$WORK/dev0.log" && echo ok)" "--dev-id: binds 127.0.0.1 with 2 workers"
  check "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" | grep -q 200 && echo ok)" "--dev-id: answers on 127.0.0.1"
else bad "the --dev-id server did not start"; show "$(cat "$WORK/dev0.log")"; fi
stop_server
if started dev1 -- --dev-id 1 --port "$PORT" --host 0.0.0.0; then
  check "$(grep -q "gweb: http://0.0.0.0:$PORT " "$WORK/dev1.log" && echo ok)" "--dev-id --host 0.0.0.0: opens it"
else bad "the --dev-id --host server did not start"; show "$(cat "$WORK/dev1.log")"; fi
stop_server
if started dev2 GWEB_HOST=0.0.0.0 -- --dev-id 1 --port "$PORT"; then
  check "$(grep -q "gweb: http://0.0.0.0:$PORT " "$WORK/dev2.log" && echo ok)" "--dev-id with GWEB_HOST=0.0.0.0: opens it"
else bad "the --dev-id GWEB_HOST server did not start"; show "$(cat "$WORK/dev2.log")"; fi
stop_server
printf 'GWEB_HOST=0.0.0.0\n' > "$WORK/site/.env"
if started dev3 -- --dev-id 1 --port "$PORT"; then
  check "$(grep -q "gweb: http://0.0.0.0:$PORT " "$WORK/dev3.log" && echo ok)" "--dev-id with GWEB_HOST in .env: opens it"
else bad "the --dev-id .env server did not start"; show "$(cat "$WORK/dev3.log")"; fi
stop_server
rm -f "$WORK/site/.env"
# The dev overlay and the id are served on the loopback only: the build id is not on a network address.
if started dev4 -- --dev-id 7 --port "$PORT"; then
  check "$([ "$(curl -s -m 5 "http://127.0.0.1:$PORT/__gweb/id")" = 7 ] && echo ok)" "--dev-id: /__gweb/id answers on 127.0.0.1"
  # Another local address of this machine, when it has one (not every CI runner does): refused.
  other=$( (hostname -I 2>/dev/null; ifconfig 2>/dev/null | sed -n 's/.*inet \([0-9.]*\) .*/\1/p') | tr ' ' '\n' | grep -v '^127\.' | grep '^[0-9]' | head -n 1)
  if [ -n "$other" ]; then
    check "$(! curl -s -m 3 -o /dev/null "http://$other:$PORT/__gweb/id" && echo ok)" "--dev-id: not reachable on $other"
  fi
else bad "the --dev-id id server did not start"; show "$(cat "$WORK/dev4.log")"; fi
stop_server

# gweb dev itself, for real: it must pass --dev-id, so the defaults above are what it gets.
gdev() {   # gdev NAME ARGS...: starts gweb dev and waits for the startup line
  name=$1; shift
  (cd "$WORK/site" && exec env GOOSE="${GOOSE:-goose}" "$GWEB" dev "$@" >"$WORK/$name.log" 2>&1) &
  DPID=$!
  PIDS="$PIDS $DPID"
  poll 240 grep -q 'gweb: http://' "$WORK/$name.log"
}
stop_dev() { kill_tree "$DPID"; wait "$DPID" 2>/dev/null; poll 20 sh -c "! curl -s -m 1 -o /dev/null http://127.0.0.1:$PORT/"; }
if gdev gdev0 --port "$PORT"; then
  check "$(grep -q "gweb: http://127.0.0.1:$PORT (2 workers)" "$WORK/gdev0.log" && echo ok)" "gweb dev binds 127.0.0.1 by default"
  check "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" | grep -q 200 && echo ok)" "gweb dev answers on 127.0.0.1"
  check "$(alive "$DPID" && echo ok)" "gweb dev is still running"
else bad "gweb dev did not start"; show "$(tail -n 20 "$WORK/gdev0.log")"; fi
stop_dev
if gdev gdev1 --port "$PORT" --host 0.0.0.0; then
  check "$(grep -q "gweb: http://0.0.0.0:$PORT " "$WORK/gdev1.log" && echo ok)" "gweb dev --host 0.0.0.0 opts in to the network"
else bad "gweb dev --host did not start"; show "$(tail -n 20 "$WORK/gdev1.log")"; fi
stop_dev

echo "config.sh: $pass of $((pass + fail)) checks passed"
[ "$fail" -eq 0 ]
