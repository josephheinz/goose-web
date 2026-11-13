#!/bin/sh
# gweb with goose-postgres: `package pg ...` in gweb.packages, so an app file says `import pg;`.
#
#   GOOSE=/path/to/goose test/pgdeps.sh
#
# test/pgdeps/app is a copy of goose-postgres's examples/notes. The checkout is ../goose-postgres, or $PG_SRC.
# 1. gweb gen declares pg in the root; gweb check passes (no server, no C library).
# 2. gweb build links libpq. Skipped, with a message, when libpq-fe.h is not found.
# 3. A throwaway PostgreSQL server (initdb, pg_ctl) and curl exercise the routes. Skipped, with a message, when
#    pg_ctl is missing.
#
# Needs gweb built beside this folder.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
PORT=${PORT:-4022}
PGP=${PG_TEST_PORT:-54341}
if [ ! -x "$GWEB" ]; then
  echo "pgdeps.sh: $GWEB is missing; build it first: goose build -o gweb cli/gweb.goose"
  exit 1
fi
PGSRC=${PG_SRC:-$ROOT/../goose-postgres}
if [ ! -f "$PGSRC/pg.goose" ]; then
  echo "pgdeps.sh: SKIP, no goose-postgres checkout at $PGSRC (set PG_SRC)"
  exit 0
fi
PGSRC=$(cd "$PGSRC" && pwd -P)
goose=${GOOSE:-}
[ -z "$goose" ] && goose=$(command -v goose 2>/dev/null || true)
if [ -z "$goose" ]; then
  echo "pgdeps.sh: SKIP, no goose compiler (set GOOSE or put goose on PATH)"
  exit 0
fi
export GWEB_PKG_PG="$PGSRC"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-pgdeps.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
PID=""
BIN=""
STARTED=""
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  if [ -n "$STARTED" ]; then
    "$BIN/pg_ctl" -D "$PGDATA" -m immediate -w -t 20 stop >/dev/null 2>&1
  fi
  rm -rf "${WORK:?}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { if [ "$1" = ok ]; then ok; else bad "$2"; fi; }
show() { echo "$1" | sed 's/^/    /'; }

cp -R "$HERE/pgdeps/app" "$WORK/app"

# 1. gen and check.
if out=$("$GWEB" -C "$WORK/app" gen 2>&1); then
  check "$(grep -qF "import pg from \"$PGSRC\";" "$WORK/app/.gweb/main.goose" && echo ok)" "gen: the root declares pg from the local checkout"
else bad "gweb gen"; show "$out"; fi
if out=$("$GWEB" -C "$WORK/app" check 2>&1); then ok; else bad "gweb check"; show "$out"; fi

# Without the override the line is written as it stands.
if out=$(env -u GWEB_PKG_PG "$GWEB" -C "$WORK/app" gen 2>&1); then
  check "$(grep -qF 'import pg from "josephheinz/goose-postgres@v0.1.0";' "$WORK/app/.gweb/main.goose" && echo ok)" "gen: the line as written, without the override"
else bad "gweb gen without the override"; show "$out"; fi

# 2. Build.
have_libpq=""
for d in /opt/homebrew/opt/libpq/include /usr/local/opt/libpq/include /opt/homebrew/include /usr/local/include /usr/include/postgresql /usr/include; do
  [ -f "$d/libpq-fe.h" ] && have_libpq=yes
done
if [ -z "$have_libpq" ]; then
  echo "pgdeps.sh: SKIP build and server: libpq-fe.h not found (brew install libpq, or apt install libpq-dev)"
  echo "pgdeps.sh: $pass of $((pass + fail)) checks passed"
  [ "$fail" -eq 0 ]
  exit
fi
if out=$("$GWEB" -C "$WORK/app" build 2>&1); then ok; else bad "gweb build"; show "$out"; echo "pgdeps.sh: $pass of $((pass + fail)) checks passed"; exit 1; fi

# 3. A throwaway server.
find_bin() {
  if [ -n "${PG_BIN:-}" ] && [ -x "$PG_BIN/initdb" ]; then echo "$PG_BIN"; return; fi
  if command -v initdb >/dev/null 2>&1; then dirname "$(command -v initdb)"; return; fi
  best=""
  for d in /opt/homebrew/opt/postgresql@*/bin /usr/local/opt/postgresql@*/bin /usr/lib/postgresql/*/bin; do
    [ -x "$d/initdb" ] && best=$d
  done
  [ -n "$best" ] && echo "$best"
}
BIN=$(find_bin)
if [ -z "$BIN" ] || [ ! -x "$BIN/pg_ctl" ]; then
  echo "pgdeps.sh: SKIP server checks: pg_ctl not found (brew install postgresql@18, apt install postgresql, or PG_BIN)"
  echo "pgdeps.sh: $pass of $((pass + fail)) checks passed"
  [ "$fail" -eq 0 ]
  exit
fi
LC_ALL=C; export LC_ALL
# A Unix socket path stays under about 100 bytes, so the server's folder is short.
SOCK=$(mktemp -d "${TMPDIR:-/tmp}/gpg.XXXXXX")
case "$SOCK" in ???????????????????????????????????????????????????*) rmdir "$SOCK"; SOCK=$(mktemp -d /tmp/gpg.XXXXXX) ;; esac
PGDATA="$SOCK/data"
trap 'cleanup; rm -rf "${SOCK:?}"' EXIT
if ! "$BIN/initdb" -D "$PGDATA" -U postgres -A trust --no-sync -E UTF8 --locale=C >"$SOCK/initdb.log" 2>&1; then
  bad "initdb"; show "$(cat "$SOCK/initdb.log")"
else
  if "$BIN/pg_ctl" -D "$PGDATA" -w -t 60 -l "$SOCK/server.log" \
       -o "-p $PGP -k $SOCK -c listen_addresses= -c fsync=off -c synchronous_commit=off -c max_connections=100" start >"$SOCK/start.log" 2>&1; then
    STARTED=yes
    "$BIN/createdb" -h "$SOCK" -p "$PGP" -U postgres gtest
    export PG_EXAMPLE_CONN="host=$SOCK port=$PGP user=postgres dbname=gtest"
    (cd "$WORK/app" && GWEB_WORKERS=4 exec ./.gweb/server --port "$PORT" --host 127.0.0.1 >"$WORK/server.log" 2>&1) &
    PID=$!
    URL="http://127.0.0.1:$PORT"
    n=0
    up=""
    while [ "$n" -lt 120 ]; do
      if curl -s -o /dev/null "$URL/api/notes"; then up=yes; break; fi
      sleep 0.25
      n=$((n + 1))
    done
    if [ -z "$up" ]; then bad "the server did not answer on port $PORT"; show "$(cat "$WORK/server.log")"
    else
      TOKEN=0123456789abcdef0123456789abcdef       # the CSRF token is a cookie and a header with the same value
      post() { curl -s -o "$WORK/body" -w '%{http_code}' -H "Cookie: gw_csrf=$TOKEN" -H "X-CSRF-Token: $TOKEN" -X POST "$URL/api/notes?text=$1"; }
      check "$([ "$(curl -s "$URL/api/notes")" = "[]" ] && echo ok)" "empty list"
      check "$([ "$(post hello)" = 201 ] && [ "$(cat "$WORK/body")" = '{"id":1}' ] && echo ok)" "add first: 201 and the id"
      check "$([ "$(post world)" = 201 ] && echo ok)" "add second"
      check "$([ "$(post hello)" = 409 ] && [ "$(cat "$WORK/body")" = '{"error":"23505"}' ] && echo ok)" "duplicate is a conflict"
      check "$([ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/api/notes?text=nope")" = 403 ] && echo ok)" "no CSRF token: 403"
      case "$(curl -s "$URL/api/notes")" in '[{"id":1,"text":"hello","at":'*'},{"id":2,"text":"world","at":'*'}]') ok ;; *) bad "list of two notes" ;; esac
    fi
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    [ -n "$PID" ] && wait "$PID" 2>/dev/null
    case "$(ps -o stat= -p "$PID" 2>/dev/null | tr -d ' ')" in Z*) bad "the app server is a zombie" ;; esac
    PID=""
    "$BIN/pg_ctl" -D "$PGDATA" -m immediate -w -t 20 stop >/dev/null 2>&1
    STARTED=""
    # A stopped server leaves no postgres process of its own, and no zombie.
    n=0
    while [ "$n" -lt 100 ]; do
      ps -A -o command= | grep -F "$PGDATA" | grep -v grep >/dev/null || break
      sleep 0.1
      n=$((n + 1))
    done
    ps -A -o command= | grep -F "$PGDATA" | grep -v grep >/dev/null && bad "server processes left behind"
    zombies=$(ps -A -o stat=,command= 2>/dev/null | grep '^Z' | grep -F postgres)
    [ -z "$zombies" ] || bad "zombie processes: $zombies"
  else
    bad "pg_ctl start"; show "$(cat "$SOCK/start.log" "$SOCK/server.log" 2>/dev/null)"
  fi
fi

echo "pgdeps.sh: $pass of $((pass + fail)) checks passed"
[ "$fail" -eq 0 ]
