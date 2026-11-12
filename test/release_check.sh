#!/bin/sh
# Rehearses a release without a network: tags copies of the three checkouts in local
# bare repos and runs the suites with every package declared from a file:// source.
#
#   GOOSE=/path/to/goose test/release_check.sh
#
# Needs git, curl, python3, node, a C compiler (cc), and gweb built beside this folder.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
LAB=$(dirname "$ROOT")
: "${GOOSE:?set GOOSE to the goose compiler}"
TAG="v$(tr -d '[:space:]' < "$ROOT/VERSION")"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-release.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export GOOSE_HOME="$WORK/home"
mkdir -p "$GOOSE_HOME"

publish() {
  name=$1
  dir=$2
  [ -d "$dir" ] || { echo "release_check: $dir is missing" >&2; exit 1; }
  mkdir -p "$WORK/src/$name"
  (cd "$dir" && git ls-files -co --exclude-standard -z | tar -c --null -T -) | tar -x -C "$WORK/src/$name"
  (
    cd "$WORK/src/$name"
    git init -q -b main
    git add -A
    git -c user.name=release_check -c user.email=release_check@localhost commit -q -m "release rehearsal"
    git tag "$TAG"
  )
  git clone -q --bare "$WORK/src/$name" "$WORK/$name.git"
}

publish goose-net "$LAB/goose-net"
publish goose-sqlite "$LAB/goose-sqlite"
publish goose-web "$ROOT"

export GWEB_WEB="file://$WORK/goose-web.git@$TAG"
export GWEB_NET="file://$WORK/goose-net.git@$TAG"
export GWEB_SQLITE="file://$WORK/goose-sqlite.git@$TAG"

failed=0
step() {
  name=$1
  shift
  if "$@" >"$WORK/out.txt" 2>&1; then
    echo "ok   $name: $(tail -n 1 "$WORK/out.txt")"
  else
    echo "FAIL $name"
    tail -n 20 "$WORK/out.txt"
    failed=1
  fi
}

cookie_test() {
  mkdir "$WORK/cookie"
  sed -e "s|^import web from \"..\";|import web from \"$GWEB_WEB\";|" \
      -e "s|^import net from \"../../goose-net\";|import net from \"$GWEB_NET\";|" \
      "$HERE/cookie_test.goose" > "$WORK/cookie/cookie_test.goose"
  "$GOOSE" build -o "$WORK/cookie/cookie_test" "$WORK/cookie/cookie_test.goose"
  "$WORK/cookie/cookie_test"
}

csrf_test() {
  mkdir "$WORK/csrf"
  sed -e "s|^import web from \"..\";|import web from \"$GWEB_WEB\";|" \
      -e "s|^import net from \"../../goose-net\";|import net from \"$GWEB_NET\";|" \
      "$HERE/csrf_test.goose" > "$WORK/csrf/csrf_test.goose"
  "$GOOSE" build -o "$WORK/csrf/csrf_test" "$WORK/csrf/csrf_test.goose"
  "$WORK/csrf/csrf_test"
}

catchall_test() {
  mkdir "$WORK/catchall"
  sed -e "s|^import web from \"..\";|import web from \"$GWEB_WEB\";|" \
      -e "s|^import net from \"../../goose-net\";|import net from \"$GWEB_NET\";|" \
      "$HERE/catchall_test.goose" > "$WORK/catchall/catchall_test.goose"
  "$GOOSE" build -o "$WORK/catchall/catchall_test" "$WORK/catchall/catchall_test.goose"
  "$WORK/catchall/catchall_test"
}

# The auth suite's Goose tests, the same pattern as cookie_test.
goose_test() {
  name=$1
  mkdir "$WORK/$name"
  sed -e "s|^import web from \"..\";|import web from \"$GWEB_WEB\";|" \
      -e "s|^import net from \"../../goose-net\";|import net from \"$GWEB_NET\";|" \
      "$HERE/$name.goose" > "$WORK/$name/$name.goose"
  "$GOOSE" build -o "$WORK/$name/$name" "$WORK/$name/$name.goose"
  "$WORK/$name/$name"
}

# The C tests need a C compiler, no network.
c_test() {
  name=$1
  shift
  mkdir -p "$WORK/c"
  cc -O2 -Wall -o "$WORK/c/$name" "$HERE/$name.c" "$@"
  "$WORK/c/$name"
}

step cookie_test cookie_test
step csrf_test csrf_test
step catchall_test catchall_test
step crypto_test goose_test crypto_test
step env_test goose_test env_test
step session_test goose_test session_test
step rate_test goose_test rate_test
step security_test goose_test security_test
step crypto_test.c c_test crypto_test "$ROOT/src/crypto.c"
step env_test.c c_test env_test "$ROOT/src/sys.c"
step rate_test.c c_test rate_test "$ROOT/src/rate.c" -lpthread
step components sh "$HERE/components.sh"
step templates sh "$HERE/templates.sh"
step fragments env PORT="${PORT:-3991}" sh "$HERE/fragments.sh"
step catchall env PORT="${PORT:-3994}" sh "$HERE/catchall.sh"
step forms env PORT="${PORT:-3995}" sh "$HERE/forms.sh"
step errors env PORT="${PORT:-3996}" sh "$HERE/errors.sh"
step frag sh "$HERE/frag.sh"
step upload_c sh "$HERE/upload_c.sh"
step inflight_c sh "$HERE/inflight_c.sh"
step auth env PORT="${PORT:-3997}" sh "$HERE/auth.sh"

gweb_new() {
  mkdir "$WORK/lone"
  cp "$ROOT/gweb" "$WORK/lone/gweb"
  (cd "$WORK/lone" && ./gweb new site && ./gweb -C site build)
}
step "lone gweb new and build" gweb_new

[ "$failed" -eq 0 ] && echo "release_check: all passed ($TAG)"
exit "$failed"
