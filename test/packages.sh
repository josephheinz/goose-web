#!/bin/sh
# gweb's package suite (DESIGN-ADDENDUM-18, D6 and Step 6).
#
#   GOOSE=/path/to/goose test/packages.sh
#
# test/packages/app is a project that mounts test/packages/pkg at /admin through gweb.packages.
# 1. gweb routes lists the package routes and its public file; gweb gen links the package lib.
# 2. With a Goose compiler: the project is built and started; curl checks the package page inside the
#    project's root layout, the package route, the public file and the project page's package component.
# 3. Each error, in its own copy, must fail gweb gen with its message.
# 4. Nested mounts: a package inside another's mount, in either line order, with a local folder.
# 5. A git source by URL (file:// and https://) is cloned into the package cache once and used from there.
#
# Needs curl and git, and gweb built beside this folder (goose build -o gweb cli/gweb.goose).
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
  check "$([ -L "$WORK/ok/app/.gweb/admin" ] && [ -f "$WORK/ok/app/.gweb/admin/users.goose" ] && [ -f "$WORK/ok/app/.gweb/Badge.goose" ] && echo ok)" \
    "gweb gen: .gweb/admin links the package lib and Badge.goose exists"
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
    "$WORK/ok/app/.gweb/server" --port "$PORT" >/dev/null 2>&1 &
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
      check "$([ "$(cat "$WORK/css.s")" = 200 ] && grep -q 'color:teal' "$WORK/css.b" && echo ok)" "GET /admin/x.css: the package's public file (minified)"
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

# 4. Nested mounts: ../outer at /admin and ../inner at /admin/shop (inner is a folder of the project in `local`).
nest() {
  fresh "$1"
  cp -R "$HERE/packages/outer" "$WORK/$1/outer"
  cp -R "$HERE/packages/inner" "$WORK/$1/inner"
  printf '%s\n' "$2" > "$WORK/$1/app/gweb.packages"
  rm -f "$WORK/$1/app/app/page.goose"
  echo '<h1>project-home</h1>' > "$WORK/$1/app/app/page.html"
}
nest nest '../outer at /admin
../inner at /admin/shop'
routes=$("$GWEB" -C "$WORK/nest/app" routes 2>&1)
for want in '/admin/shop  ' '/admin/shop/orders' '/admin/c'; do
  case "$routes" in *"$want"*) ok ;; *) bad "nest: gweb routes lacks '$want':"; echo "$routes" | sed 's/^/    /' ;; esac
done
nest rev '../inner at /admin/shop
../outer at /admin'
routes=$("$GWEB" -C "$WORK/rev/app" routes 2>&1)
case "$routes" in *'/admin/shop/orders'*) ok ;; *) bad "rev: reversed lines: gweb routes lacks /admin/shop/orders"; echo "$routes" | sed 's/^/    /' ;; esac
if [ -n "$goose" ]; then
  if out=$("$GWEB" -C "$WORK/nest/app" build 2>&1); then
    "$WORK/nest/app/.gweb/server" --port "$PORT" >/dev/null 2>&1 &
    PID=$!
    up=""
    for i in 1 2 3 4 5 6 7 8 9 10; do
      sleep 0.5
      if curl -s -o /dev/null "$URL/"; then up=yes; break; fi
    done
    if [ -z "$up" ]; then
      bad "nest: the server did not answer on port $PORT"
    else
      curl -s -D "$WORK/ord.h" -o "$WORK/ord.b" -w '%{http_code}' "$URL/admin/shop/orders" > "$WORK/ord.s"
      check "$([ "$(cat "$WORK/ord.s")" = 200 ] && grep -q 'shop-orders' "$WORK/ord.b" && grep -q 'data-root-layout' "$WORK/ord.b" && grep -q 'data-outer-layout' "$WORK/ord.b" && grep -qi '^x-outer: 1' "$WORK/ord.h" && echo ok)" \
        "GET /admin/shop/orders: the inner page in the project's layout and the outer package's, with the outer middleware's header"
      curl -s -o "$WORK/shop.b" -w '%{http_code}' "$URL/admin/shop" > "$WORK/shop.s"
      check "$([ "$(cat "$WORK/shop.s")" = 200 ] && grep -q 'shop-home' "$WORK/shop.b" && echo ok)" "GET /admin/shop: 200"
    fi
    kill "$PID" 2>/dev/null
    wait "$PID" 2>/dev/null
    PID=""
  else
    bad "gweb build of the nested project"; echo "$out"
  fi
fi

nest deep '../outer at /admin
../inner at /admin/shop/x/y'
expect_ok() { if out=$("$GWEB" -C "$WORK/$1/app" gen 2>&1); then ok; else bad "$1: gweb gen failed"; echo "$out" | sed 's/^/    /'; fi; }
expect_ok deep

nest nestclash '../outer at /admin
../inner at /admin/shop'
mkdir -p "$WORK/nestclash/outer/app/shop"
expect_fail nestclash 'gweb.packages:2: error: shop: mounted at /admin/shop, but package outer (mounted at /admin, gweb.packages:1) has the folder '
case "$out" in *"outer/app/shop"*) ok ;; *) bad "nestclash: the error does not name the folder" ;; esac

nest nestdeep '../inner at /admin/shop
../outer at /admin'
mkdir -p "$WORK/nestdeep/outer/app/shop/z"
expect_fail nestdeep 'gweb.packages:1: error: shop: mounted at /admin/shop, but package outer'

nest same '../outer at /admin
../inner at /admin'
expect_fail same 'is also the mount of package'

nest inside '../outer at /admin
./app/shop at /admin/shop'
cp -R "$HERE/packages/inner" "$WORK/inside/app/app/shop"
expect_fail inside "this package folder is inside the project's app/ folder"

nest local '../outer at /admin
./admin/shop at /admin/shop'
mkdir -p "$WORK/local/app/admin"
cp -R "$HERE/packages/inner" "$WORK/local/app/admin/shop"
expect_ok local
routes=$("$GWEB" -C "$WORK/local/app" routes 2>&1)
case "$routes" in *'/admin/shop/orders'*) ok ;; *) bad "local: a package inside the project folder: routes lacks /admin/shop/orders" ;; esac


# 5. A git source by URL: file:///path/to/repo.git@tag (and https://host/path@tag), cloned into the package cache.
GITBASE="$WORK/gitpkgs"
mkdir -p "$GITBASE/src"
cp -R "$HERE/packages/pkg/." "$GITBASE/src/"
if (cd "$GITBASE/src" && git init -q -b main && git add -A && git -c maintenance.auto=false -c gc.auto=0 -c user.name=t -c user.email=t@localhost commit -q -m pkg && git tag v1) \
   && git clone -q --bare "$GITBASE/src" "$GITBASE/pkg.git"; then
  export GWEB_PKG_CACHE="$WORK/pkgcache"
  fresh url
  printf '# a package from a repo by URL\nfile://%s/pkg.git@v1 at /admin\n' "$GITBASE" > "$WORK/url/app/gweb.packages"
  routes=$("$GWEB" -C "$WORK/url/app" routes 2>&1)
  for want in '/admin  ' '/admin/users' '/admin/x.css'; do
    case "$routes" in *"$want"*) ok ;; *) bad "url source: gweb routes lacks '$want':"; echo "$routes" | sed 's/^/    /' ;; esac
  done
  check "$([ -f "$GWEB_PKG_CACHE"/url/*/gweb.package ] && echo ok)" "url source: the repo was cloned into the cache under url/"
  if out=$("$GWEB" -C "$WORK/url/app" gen 2>&1); then
    check "$([ -L "$WORK/url/app/.gweb/admin" ] && [ -f "$WORK/url/app/.gweb/Badge.goose" ] && echo ok)" "url source: gweb gen links the package lib and its component"
  else
    bad "url source: gweb gen"; echo "$out" | sed 's/^/    /'
  fi
  # A cached tag is never fetched again: with the repo gone, the cache serves it.
  rm -rf "$GITBASE/pkg.git"
  if out=$("$GWEB" -C "$WORK/url/app" gen 2>&1); then ok; else bad "url source: the cached tag was fetched again"; echo "$out" | sed 's/^/    /'; fi
  # Errors.
  expect_url_fail() {
    fresh urlbad
    printf '%s\n' "$1" > "$WORK/urlbad/app/gweb.packages"
    if out=$("$GWEB" -C "$WORK/urlbad/app" gen 2>&1); then bad "'$1': gweb gen succeeded"; else
      case "$out" in *"$2"*) ok ;; *) bad "'$1': wanted '$2', got:"; echo "$out" | sed 's/^/    /' ;; esac
    fi
  }
  expect_url_fail 'file:///no/such/repo.git@v1 at /admin' 'git clone failed'
  expect_url_fail 'file:///tmp/../etc/x.git@v1 at /admin' 'a URL source is file:///path/to/repo@tag or https://host/path@tag'
  expect_url_fail 'file:///tmp/a$b.git@v1 at /admin' 'a URL source is file:///path/to/repo@tag or https://host/path@tag'
  expect_url_fail 'file:///tmp/x.git@-v1 at /admin' 'a URL source is file:///path/to/repo@tag or https://host/path@tag'
  expect_url_fail 'file:///tmp/x.git@v1/x at /admin' 'a URL source is file:///path/to/repo@tag or https://host/path@tag'
else
  bad "git: could not make the package repo"
fi

echo "packages.sh: $pass of $((pass + fail)) checks passed"
[ "$fail" -eq 0 ]
