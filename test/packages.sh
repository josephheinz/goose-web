#!/bin/sh
# goose-web's package suite (DESIGN-ADDENDUM-18, D6 and Step 6).
#
#   GOOSE=/path/to/goose test/packages.sh
#
# test/packages/app is a project that mounts test/packages/pkg at /admin through gweb.packages.
# 1. gweb routes lists the package routes and its public file; gweb gen links the package lib.
# 2. With a Goose compiler: the project is built and started; curl checks the package page inside the
#    project's root layout, the package route, the public file and the project page's package component.
# 3. Each error, in its own copy, must fail gweb gen with its message.
#
# Needs curl, and gweb built beside this folder (goose build -o gweb cli/gweb.goose).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
PORT=${PORT:-3996}
if [ ! -x "$GWEB" ]; then
  echo "packages.sh: $GWEB is missing; build it first: goose build -o gweb cli/gweb.goose"
  exit 1
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-packages.XXXXXX")
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
VERSION=$(tr -d '\n' < "$ROOT/VERSION")

# fresh NAME: $WORK/NAME/app is the project and $WORK/NAME/pkg the package, so ../pkg holds.
fresh() {
  rm -rf "$WORK/$1"
  mkdir -p "$WORK/$1"
  cp -R "$HERE/packages/app" "$WORK/$1/app"
  cp -R "$HERE/packages/pkg" "$WORK/$1/pkg"
}

# 1. gweb routes and gweb gen.
fresh ok
routes=$("$GWEB" -C "$WORK/ok/app" routes 2>&1)
for want in '/admin  ' '/admin/users' '/admin/x.css'; do
  case "$routes" in *"$want"*) ok ;; *) bad "gweb routes lacks '$want':"; echo "$routes" | sed 's/^/    /' ;; esac
done
if out=$("$GWEB" -C "$WORK/ok/app" gen 2>&1); then
  check "$([ -L "$WORK/ok/app/.gooseweb/admin" ] && [ -f "$WORK/ok/app/.gooseweb/admin/users.goose" ] && [ -f "$WORK/ok/app/.gooseweb/Badge.goose" ] && echo ok)" \
    "gweb gen: .gooseweb/admin links the package lib and Badge.goose exists"
else
  bad "gweb gen of the project"; echo "$out"
fi

# 2. Build and serve, when there is a compiler.
goose=${GOOSE:-}
[ -z "$goose" ] && goose=$(command -v goose 2>/dev/null || true)
URL="http://127.0.0.1:$PORT"
if [ -z "$goose" ]; then
  echo "SKIP build and server checks: no goose compiler (set GOOSE or put goose on PATH)"
else
  if out=$("$GWEB" -C "$WORK/ok/app" build 2>&1); then
    "$WORK/ok/app/.gooseweb/server" --port "$PORT" >/dev/null 2>&1 &
    PID=$!
    up=""
    for i in 1 2 3 4 5 6 7 8 9 10; do
      sleep 0.5
      if curl -s -o /dev/null "$URL/"; then up=yes; break; fi
    done
    if [ -z "$up" ]; then
      bad "the server did not answer on port $PORT"
    else
      curl -s -o "$WORK/home.b" -w '%{http_code}' "$URL/" > "$WORK/home.s"
      check "$([ "$(cat "$WORK/home.s")" = 200 ] && grep -q 'project-home' "$WORK/home.b" && grep -q 'badge 7' "$WORK/home.b" && grep -q 'data-root-layout' "$WORK/home.b" && echo ok)" \
        "GET /: 200, the project page with the package component Badge"
      curl -s -o "$WORK/adm.b" -w '%{http_code}' "$URL/admin" > "$WORK/adm.s"
      check "$([ "$(cat "$WORK/adm.s")" = 200 ] && grep -q 'admin-home users=3' "$WORK/adm.b" && grep -q 'data-root-layout' "$WORK/adm.b" && grep -q 'data-pkg-layout' "$WORK/adm.b" && echo ok)" \
        "GET /admin: 200, the package page (using its lib) inside the project's root layout and its own"
      curl -s -o "$WORK/usr.b" -w '%{http_code}' "$URL/admin/users" > "$WORK/usr.s"
      check "$([ "$(cat "$WORK/usr.s")" = 200 ] && grep -q 'admin-users' "$WORK/usr.b" && echo ok)" "GET /admin/users: 200, the package route"
      curl -s -D "$WORK/css.h" -o "$WORK/css.b" -w '%{http_code}' "$URL/admin/x.css" > "$WORK/css.s"
      check "$([ "$(cat "$WORK/css.s")" = 200 ] && cmp -s "$WORK/css.b" "$HERE/packages/pkg/public/x.css" && echo ok)" "GET /admin/x.css: the package's public file"
      curl -s -o /dev/null -w '%{http_code}' "$URL/x.css" > "$WORK/nox.s"
      check "$([ "$(cat "$WORK/nox.s")" = 404 ] && echo ok)" "GET /x.css: 404, the file is served under the mount only"
    fi
    kill "$PID" 2>/dev/null
    wait "$PID" 2>/dev/null
    PID=""
  else
    bad "gweb build of the project"; echo "$out"
  fi
fi

# 3. Errors. expect_fail NAME WANT: the copy NAME (changed by the caller) must fail gweb gen with WANT in its output.
expect_fail() {
  if out=$("$GWEB" -C "$WORK/$1/app" gen 2>&1); then
    bad "$1: gweb gen succeeded"
  else
    case "$out" in
      *"$2"*) ok ;;
      *) bad "$1: wanted '$2', got:"; echo "$out" | sed 's/^/    /' ;;
    esac
  fi
}

fresh clash
mkdir -p "$WORK/clash/app/components"
cp "$HERE/packages/pkg/components/Badge.gshtml" "$WORK/clash/app/components/Badge.gshtml"
expect_fail clash 'error: component Badge is also defined in '
case "$out" in
  *"components/Badge.gshtml"*) ok ;;
  *) bad "clash: the error does not name the component files" ;;
esac

fresh folder
mkdir -p "$WORK/folder/app/app/admin"
expect_fail folder 'app/admin: error: admin: the project has this folder, so the package cannot be mounted at /admin'

fresh state
echo 'fn handle() {}' > "$WORK/state/pkg/app/state.goose"
expect_fail state 'pkg/app/state.goose: error: a package has no state.goose'

fresh notfound
echo '<p>nope</p>' > "$WORK/notfound/pkg/app/not-found.html"
expect_fail notfound 'pkg/app/not-found.html: error: a package has no not-found.html'

fresh version
printf 'name admin\ngweb 9.0\n' > "$WORK/version/pkg/gweb.package"
expect_fail version "gweb.package:2: error: admin: needs gweb 9.0 or newer (this is $VERSION)"

fresh mount
printf '../pkg at /[id]\n' > "$WORK/mount/app/gweb.packages"
expect_fail mount 'gweb.packages:1: error: at needs a mount like /admin'

fresh nomount
printf '../pkg\n' > "$WORK/nomount/app/gweb.packages"
expect_fail nomount 'error: admin: a package without `at` has no app/ folder'

fresh missing
printf '# none here\n../nowhere at /x\n' > "$WORK/missing/app/gweb.packages"
expect_fail missing 'gweb.packages:2: error: ../nowhere: not a folder'

echo "packages.sh: $pass of $((pass + fail)) checks passed"
[ "$fail" -eq 0 ]
