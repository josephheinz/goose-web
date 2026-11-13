#!/bin/sh
# gweb's Goose-package suite: `package NAME SOURCE` lines in gweb.packages and gweb.package (gweb 1.1).
#
#   GOOSE=/path/to/goose test/pkgdeps.sh
#
# test/pkgdeps/app imports the C-free package test/pkgdeps/fakelib, declared by `package fakelib ../fakelib`.
# 1. gweb gen writes `import fakelib from "..."` in the root; gweb check, test, lsp-gen and export use it too.
# 2. The built server answers a route that calls the package. A gweb package may need a Goose package itself.
# 3. Each error, in its own copy, must fail gweb gen with its message.
# 4. $GWEB_PKG_NAME replaces a source. A folder named package, mounted with `at`, still works.
#
# test/pgdeps.sh is the same with goose-postgres. Needs curl, and gweb built beside this folder.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
PORT=${PORT:-4021}
if [ ! -x "$GWEB" ]; then
  echo "pkgdeps.sh: $GWEB is missing; build it first: goose build -o gweb cli/gweb.goose"
  exit 1
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-pkgdeps.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
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

# fresh NAME: $WORK/NAME/{app,fakelib,admin}, so ../fakelib holds.
fresh() {
  mkdir -p "${WORK:?}/${1:?}"
  cp -R "$HERE/pkgdeps/app" "$WORK/$1/app"
  cp -R "$HERE/pkgdeps/fakelib" "$WORK/$1/fakelib"
  cp -R "$HERE/pkgdeps/admin" "$WORK/$1/admin"
}
expect_fail() {   # expect_fail NAME WANT
  if out=$("$GWEB" -C "$WORK/$1/app" gen 2>&1); then bad "$1: gweb gen succeeded"
  else case "$out" in *"$2"*) ok ;; *) bad "$1: wanted '$2', got:"; show "$out" ;; esac; fi
}
expect_ok() {
  if out=$("$GWEB" -C "$WORK/$1/app" gen 2>&1); then ok; else bad "$1: gweb gen failed"; show "$out"; fi
}
# wait_up URL SECONDS: waits for the server to answer.
wait_up() {
  n=0
  while [ "$n" -lt $(($2 * 4)) ]; do
    if curl -s -o /dev/null "$1"; then return 0; fi
    sleep 0.25
    n=$((n + 1))
  done
  return 1
}
stop_server() {
  [ -z "$PID" ] && return
  kill "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null
  case "$(ps -o stat= -p "$PID" 2>/dev/null | tr -d ' ')" in Z*) bad "the server is a zombie" ;; esac
  PID=""
}

# 1. gen, check, test, lsp-gen, export.
fresh ok
if out=$("$GWEB" -C "$WORK/ok/app" gen 2>&1); then
  main="$WORK/ok/app/.gweb/main.goose"
  check "$(grep -q '^import fakelib from "'"$WORK"'/ok/fakelib";$' "$main" && echo ok)" "gen: main.goose has import fakelib from the absolute path"
else
  bad "gweb gen"; show "$out"
fi

goose=${GOOSE:-}
[ -z "$goose" ] && goose=$(command -v goose 2>/dev/null || true)
if [ -z "$goose" ]; then
  echo "SKIP build, check, test and export: no goose compiler (set GOOSE or put goose on PATH)"
else
  if out=$("$GWEB" -C "$WORK/ok/app" check 2>&1); then
    check "$(grep -q '^import fakelib from ' "$WORK/ok/app/.gweb.check/main.goose" && echo ok)" "check: the check root declares fakelib"
  else bad "gweb check"; show "$out"; fi
  if out=$("$GWEB" -C "$WORK/ok/app" test 2>&1); then
    case "$out" in *"routes: 1 tests, "*" 0 failed"*) ok ;; *) bad "gweb test: wanted 1 passing test"; show "$out" ;; esac
    check "$(grep -q '^import fakelib from ' "$WORK/ok/app/.gweb.test/main.goose" && echo ok)" "test: the test root declares fakelib"
  else bad "gweb test"; show "$out"; fi
  "$GWEB" -C "$WORK/ok/app" lsp-gen >/dev/null 2>&1
  check "$(grep -q '^import fakelib from ' "$WORK/ok/app/.gweb.lsp/main.goose" && echo ok)" "lsp-gen: the lsp root declares fakelib"
  if out=$("$GWEB" -C "$WORK/ok/app" export -o "$WORK/ok/site" 2>&1); then
    check "$([ -f "$WORK/ok/site/index.html" ] && echo ok)" "export: wrote index.html"
  else bad "gweb export"; show "$out"; fi

  # 2. Build and serve.
  if out=$("$GWEB" -C "$WORK/ok/app" build 2>&1); then
    "$WORK/ok/app/.gweb/server" --port "$PORT" >/dev/null 2>&1 &
    PID=$!
    URL="http://127.0.0.1:$PORT"
    if wait_up "$URL/" 20; then
      check "$([ "$(curl -s "$URL/api/hello")" = '{"answer":42}' ] && echo ok)" "GET /api/hello: the route calls the package"
    else bad "the server did not answer on port $PORT"; fi
    stop_server
  else bad "gweb build"; show "$out"; fi

  # A gweb package that needs a Goose package: no line in the project.
  fresh need
  printf '../admin at /admin\n' > "$WORK/need/app/gweb.packages"
  rm -rf "${WORK:?}/need/app/app/api" "${WORK:?}/need/app/tests"
  if out=$("$GWEB" -C "$WORK/need/app" build 2>&1); then
    check "$(grep -q '^import fakelib from ' "$WORK/need/app/.gweb/main.goose" && echo ok)" "need: the package's own package line reaches the root"
    "$WORK/need/app/.gweb/server" --port "$PORT" >/dev/null 2>&1 &
    PID=$!
    if wait_up "http://127.0.0.1:$PORT/" 20; then
      check "$([ "$(curl -s "http://127.0.0.1:$PORT/admin")" = '{"doubled":84}' ] && echo ok)" "GET /admin: the gweb package calls the Goose package it asked for"
    else bad "need: the server did not answer"; fi
    stop_server
  else bad "need: gweb build"; show "$out"; fi
fi

# The same source from the project and from a gweb package is one line; a git source is only checked, not fetched.
fresh same
printf '../admin at /admin\npackage fakelib ../fakelib\npackage fakelib %s/same/fakelib\n' "$WORK" > "$WORK/same/app/gweb.packages"
expect_ok same
check "$([ "$(grep -c '^import fakelib from ' "$WORK/same/app/.gweb/main.goose")" = 1 ] && echo ok)" "same: one import line for one source"
fresh git
printf 'package pg josephheinz/goose-postgres@v0.1.0\npackage blob file:///srv/repos/blob.git@v2\npackage other https://example.com/x/other.git@main\n' > "$WORK/git/app/gweb.packages"
expect_ok git
for want in 'import pg from "josephheinz/goose-postgres@v0.1.0";' 'import blob from "file:///srv/repos/blob.git@v2";' 'import other from "https://example.com/x/other.git@main";'; do
  check "$(grep -qF "$want" "$WORK/git/app/.gweb/main.goose" && echo ok)" "git: main.goose has $want"
done

# 3. Errors.
fresh e1
printf 'package sqlite ../fakelib\n' > "$WORK/e1/app/gweb.packages"
expect_fail e1 'gweb.packages:1: error: sqlite: this package name is taken by a module'
fresh e2
printf 'package views ../fakelib\n' > "$WORK/e2/app/gweb.packages"
expect_fail e2 'gweb.packages:1: error: views: this package name is taken by a module'
fresh e3
printf 'package 9x ../fakelib\n' > "$WORK/e3/app/gweb.packages"
expect_fail e3 'gweb.packages:1: error: package needs a Goose identifier'
fresh e4
printf 'package fakelib\n' > "$WORK/e4/app/gweb.packages"
expect_fail e4 'gweb.packages:1: error: a line is `package NAME SOURCE`'
fresh e5
printf 'package fakelib ../nowhere\n' > "$WORK/e5/app/gweb.packages"
expect_fail e5 'gweb.packages:1: error: fakelib: ../nowhere is not a folder'
fresh e6
mkdir "$WORK/e6/empty"
printf 'package fakelib ../empty\n' > "$WORK/e6/app/gweb.packages"
expect_fail e6 'has no fakelib.goose'
fresh e7
printf 'package fakelib ../fakelib extra\n' > "$WORK/e7/app/gweb.packages"
expect_fail e7 'the source has no spaces'
fresh e8
printf 'package pg a/b@v1$x\n' > "$WORK/e8/app/gweb.packages"
expect_fail e8 'pg: a/b@v1$x is not a git source'
fresh e9
printf 'package pg a/b@v1\npackage pg a/b@v2\n' > "$WORK/e9/app/gweb.packages"
expect_fail e9 'gweb.packages:2: error: pg: two sources: a/b@v1 (gweb.packages:1) and a/b@v2 (gweb.packages:2); declare one version'
# A package asks for another version than the project.
fresh e10
printf 'name admin\ngweb 1.0\npackage fakelib x/fakelib@v9\n' > "$WORK/e10/admin/gweb.package"
printf '../admin at /admin\npackage fakelib ../fakelib\n' > "$WORK/e10/app/gweb.packages"
expect_fail e10 'fakelib: two sources: '
case "$out" in *"(gweb.packages:2)"*) case "$out" in *"x/fakelib@v9 (package admin, "*"admin/gweb.package:3)"*) ok ;; *) bad "e10: the package side is not named"; show "$out" ;; esac ;; *) bad "e10: the conflict does not name both sides"; show "$out" ;; esac
# A gweb package and a Goose package with one name.
fresh e11
mkdir "$WORK/e11/adminlib"
printf 'namespace admin;\n' > "$WORK/e11/adminlib/admin.goose"
printf '../admin at /admin\npackage admin ../adminlib\n' > "$WORK/e11/app/gweb.packages"
expect_fail e11 'admin: a gweb package has this name'
fresh e12
mkdir "$WORK/e12/adminlib"
printf 'namespace admin;\n' > "$WORK/e12/adminlib/admin.goose"
printf 'package admin ../adminlib\n../admin at /admin\n' > "$WORK/e12/app/gweb.packages"
expect_fail e12 'admin: a Goose package has this name'
# A bad line in a package's own gweb.package.
fresh e13
printf 'name admin\ngweb 1.0\npackage fakelib\n' > "$WORK/e13/admin/gweb.package"
printf '../admin at /admin\n' > "$WORK/e13/app/gweb.packages"
expect_fail e13 'admin/gweb.package:3: error: a line is `package NAME SOURCE`'

# 4. $GWEB_PKG_FAKELIB replaces the source; a folder named package, mounted, still works.
fresh envp
mkdir "$WORK/envp/alt"
printf 'namespace fakelib;\nfn answer() -> i64 { return 7; }\n' > "$WORK/envp/alt/fakelib.goose"
if out=$(GWEB_PKG_FAKELIB="$WORK/envp/alt" "$GWEB" -C "$WORK/envp/app" gen 2>&1); then
  check "$(grep -q '^import fakelib from "'"$WORK"'/envp/alt";$' "$WORK/envp/app/.gweb/main.goose" && echo ok)" "env: GWEB_PKG_FAKELIB replaced the source"
else bad "env: gweb gen"; show "$out"; fi
fresh oldname
mkdir "$WORK/oldname/app/package"
printf 'name zed\ngweb 1.0\n' > "$WORK/oldname/app/package/gweb.package"
mkdir -p "$WORK/oldname/app/package/app"
printf '<p>zed</p>\n' > "$WORK/oldname/app/package/app/page.html"
printf 'package at /zed\n' > "$WORK/oldname/app/gweb.packages"
rm -rf "${WORK:?}/oldname/app/tests"
case "$("$GWEB" -C "$WORK/oldname/app" routes 2>&1)" in *"/zed"*) ok ;; *) bad "oldname: a folder named package, mounted at /zed, is not listed" ;; esac

echo "pkgdeps.sh: $pass of $((pass + fail)) checks passed"
[ "$fail" -eq 0 ]
