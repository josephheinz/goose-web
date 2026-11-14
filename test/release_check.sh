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
    # No background gc: it repacks loose objects while the clone below copies them.
    git -c maintenance.auto=false -c gc.auto=0 -c user.name=release_check -c user.email=release_check@localhost commit -q -m "release rehearsal"
    git tag "$TAG"
  )
  git clone -q --bare "$WORK/src/$name" "$WORK/$name.git"
}

publish goose-net "$LAB/goose-net"
publish goose-sqlite "$LAB/goose-sqlite"
publish gweb "$ROOT"

export GWEB_SRC="file://$WORK/gweb.git@$TAG"
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
  sed -e "s|^import gweb from \"..\";|import gweb from \"$GWEB_SRC\";|" \
      -e "s|^import net from \"../../goose-net\";|import net from \"$GWEB_NET\";|" \
      "$HERE/cookie_test.goose" > "$WORK/cookie/cookie_test.goose"
  "$GOOSE" build -o "$WORK/cookie/cookie_test" "$WORK/cookie/cookie_test.goose"
  "$WORK/cookie/cookie_test"
}

csrf_test() {
  mkdir "$WORK/csrf"
  sed -e "s|^import gweb from \"..\";|import gweb from \"$GWEB_SRC\";|" \
      -e "s|^import net from \"../../goose-net\";|import net from \"$GWEB_NET\";|" \
      "$HERE/csrf_test.goose" > "$WORK/csrf/csrf_test.goose"
  "$GOOSE" build -o "$WORK/csrf/csrf_test" "$WORK/csrf/csrf_test.goose"
  "$WORK/csrf/csrf_test"
}

meta_test() {
  mkdir "$WORK/meta"
  sed -e "s|^import gweb from \"..\";|import gweb from \"$GWEB_SRC\";|" \
      -e "s|^import net from \"../../goose-net\";|import net from \"$GWEB_NET\";|" \
      "$HERE/meta_test.goose" > "$WORK/meta/meta_test.goose"
  "$GOOSE" build -o "$WORK/meta/meta_test" "$WORK/meta/meta_test.goose"
  "$WORK/meta/meta_test"
}

sse_test() {
  mkdir "$WORK/sse"
  sed -e "s|^import gweb from \"..\";|import gweb from \"$GWEB_SRC\";|" \
      -e "s|^import net from \"../../goose-net\";|import net from \"$GWEB_NET\";|" \
      "$HERE/sse_test.goose" > "$WORK/sse/sse_test.goose"
  "$GOOSE" build -o "$WORK/sse/sse_test" "$WORK/sse/sse_test.goose"
  "$WORK/sse/sse_test"
}

catchall_test() {
  mkdir "$WORK/catchall"
  sed -e "s|^import gweb from \"..\";|import gweb from \"$GWEB_SRC\";|" \
      -e "s|^import net from \"../../goose-net\";|import net from \"$GWEB_NET\";|" \
      "$HERE/catchall_test.goose" > "$WORK/catchall/catchall_test.goose"
  "$GOOSE" build -o "$WORK/catchall/catchall_test" "$WORK/catchall/catchall_test.goose"
  "$WORK/catchall/catchall_test"
}

# The auth suite's Goose tests, the same pattern as cookie_test.
goose_test() {
  name=$1
  mkdir "$WORK/$name"
  sed -e "s|^import gweb from \"..\";|import gweb from \"$GWEB_SRC\";|" \
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

testing_test() {
  mkdir "$WORK/testing"
  sed -e "s|^import gweb from \"..\";|import gweb from \"$GWEB_SRC\";|" \
      -e "s|^import net from \"../../goose-net\";|import net from \"$GWEB_NET\";|" \
      "$HERE/testing_test.goose" > "$WORK/testing/testing_test.goose"
  "$GOOSE" build -o "$WORK/testing/testing_test" "$WORK/testing/testing_test.goose"
  "$WORK/testing/testing_test"
}

i18n_test() {
  mkdir "$WORK/i18n"
  sed -e "s|^import gweb from \"..\";|import gweb from \"$GWEB_SRC\";|" \
      -e "s|^import net from \"../../goose-net\";|import net from \"$GWEB_NET\";|" \
      "$HERE/i18n_test.goose" > "$WORK/i18n/i18n_test.goose"
  "$GOOSE" build -o "$WORK/i18n/i18n_test" "$WORK/i18n/i18n_test.goose"
  "$WORK/i18n/i18n_test"
}

step cookie_test cookie_test
step csrf_test csrf_test
step meta_test meta_test
step catchall_test catchall_test
step crypto_test goose_test crypto_test
step env_test goose_test env_test
step session_test goose_test session_test
step unauth_test goose_test unauth_test
step rate_test goose_test rate_test
step security_test goose_test security_test
step crypto_test.c c_test crypto_test "$ROOT/src/crypto.c"
step env_test.c c_test env_test "$ROOT/src/sys.c"
step rate_test.c c_test rate_test "$ROOT/src/rate.c" -lpthread
step cache_test.c c_test cache_test "$ROOT/src/cache_core.c"
step testing_test testing_test
step i18n_test i18n_test
step files_test goose_test files_test
step image_test goose_test image_test
step sandbox_test goose_test sandbox_test
step sse_test sse_test
step components sh "$HERE/components.sh"
step runtime sh "$HERE/runtime.sh"
step templates sh "$HERE/templates.sh"
step fragments env PORT="${PORT:-3991}" sh "$HERE/fragments.sh"
step catchall env PORT="${PORT:-3994}" sh "$HERE/catchall.sh"
step forms env PORT="${PORT:-3995}" sh "$HERE/forms.sh"
step errors env PORT="${PORT:-3996}" sh "$HERE/errors.sh"
step frag sh "$HERE/frag.sh"
step upload_c sh "$HERE/upload_c.sh"
step inflight_c sh "$HERE/inflight_c.sh"
step auth env PORT="${PORT:-3997}" sh "$HERE/auth.sh"
step sitemap env PORT="${PORT:-3993}" sh "$HERE/sitemap.sh"
step cache env PORT="${PORT:-3998}" sh "$HERE/cache.sh"
step push env PORT="${PORT:-3999}" sh "$HERE/push.sh"
step routes sh "$HERE/routes.sh"
step i18n env PORT="${PORT:-4000}" sh "$HERE/i18n.sh"
step valid_test goose_test valid_test
step upload_test goose_test upload_test
step markdown_test goose_test markdown_test
step srcmap sh "$HERE/srcmap.sh"
step packages env PORT="${PORT:-4001}" sh "$HERE/packages.sh"
step views sh "$HERE/views.sh"
step cmsready env PORT="${PORT:-4005}" sh "$HERE/cmsready.sh"
step tutorial env PORT="${PORT:-4002}" sh "$HERE/tutorial.sh"
step lsp sh "$HERE/lsp.sh"
step ops env PORT="${PORT:-4003}" sh "$HERE/ops.sh"
step ops_unit goose_test ops_unit
step config env PORT="${PORT:-4010}" sh "$HERE/config.sh"
step migrate sh "$HERE/migrate.sh"
step slotcheck sh "$HERE/slotcheck.sh"
step richforms sh "$HERE/richforms.sh"
step pkgdeps env PORT="${PORT:-4021}" sh "$HERE/pkgdeps.sh"
step pgdeps env PORT="${PORT:-4022}" sh "$HERE/pgdeps.sh"
step ops_c sh "$HERE/c/run.sh"

gweb_new() {
  mkdir "$WORK/lone"
  cp "$ROOT/gweb" "$WORK/lone/gweb"
  (cd "$WORK/lone" && ./gweb new site && ./gweb -C site build --strict)
}
step "lone gweb new and build" gweb_new

[ "$failed" -eq 0 ] && echo "release_check: all passed ($TAG)"
exit "$failed"
