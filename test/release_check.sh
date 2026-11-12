#!/bin/sh
# Rehearses a release without a network: tags copies of the three checkouts in local
# bare repos and runs the suites with every package declared from a file:// source.
#
#   GOOSE=/path/to/goose test/release_check.sh
#
# Needs git, curl, python3, node, and gweb built beside this folder.
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

step cookie_test cookie_test
step components sh "$HERE/components.sh"
step templates sh "$HERE/templates.sh"
step fragments env PORT="${PORT:-3991}" sh "$HERE/fragments.sh"

gweb_new() {
  mkdir "$WORK/lone"
  cp "$ROOT/gweb" "$WORK/lone/gweb"
  (cd "$WORK/lone" && ./gweb new site && ./gweb -C site build)
}
step "lone gweb new and build" gweb_new

[ "$failed" -eq 0 ] && echo "release_check: all passed ($TAG)"
exit "$failed"
