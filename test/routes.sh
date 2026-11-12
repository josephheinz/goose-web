#!/bin/sh
# goose-web's route test suite: gweb test runs tests/*.goose.
#
#   GOOSE=/path/to/goose test/routes.sh
#
# 1. test/routes/site passes under gweb test and prints its test count.
# 2. The owner state is shared: the later counter tests see the earlier POSTs.
# 3. test/routes/failing exits 1 and names its failing test.
# 4. A type error in a test file is reported at tests/<name>.goose:LINE, and a bad file name is refused.
# 5. gweb test leaves .gooseweb/ alone: the built server and main.goose keep their checksums.
#
# Needs gweb built beside this folder (goose build -o gweb cli/gweb.goose). Starts no server.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-routes.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { if [ "$1" = ok ]; then ok; else bad "$2"; fi; }
show() { echo "$1" | sed 's/^/    /'; }

# 1 and 2. The site.
cp -R "$HERE/routes/site" "$WORK/ok"
if out=$("$GWEB" -C "$WORK/ok" test 2>&1); then
  case "$out" in *"routes: 6 tests, "*" 0 failed"*) ok ;; *) bad "gweb test did not print 'routes: 6 tests ... 0 failed':"; show "$out" ;; esac
  for name in test_page test_route_json test_static_file test_post_form test_counter_second test_counter_third; do
    case "$out" in *"ok t_basic::$name"*) ok ;; *) bad "no 'ok t_basic::$name' line:"; show "$out" ;; esac
  done
else
  bad "gweb test of the site failed:"; show "$out"
fi

# 3. A failing check.
cp -R "$HERE/routes/failing" "$WORK/failing"
if out=$("$GWEB" -C "$WORK/failing" test 2>&1); then
  bad "gweb test of the failing site succeeded"
else
  case "$out" in *"FAIL t_bad::test_x"*) ok ;; *) bad "no 'FAIL t_bad::test_x' line:"; show "$out" ;; esac
  case "$out" in *"routes: 1 tests, "*" 1 failed"*) ok ;; *) bad "no 'routes: 1 tests ... 1 failed' line:"; show "$out" ;; esac
fi

# 4. Build errors.
cp -R "$HERE/routes/site" "$WORK/typo"
lines=$(wc -l < "$WORK/typo/tests/basic.goose" | tr -d ' ')
printf '\nfn test_broken(t: web::Tester&) {\n    let n: i64 = "text";\n}\n' >> "$WORK/typo/tests/basic.goose"
want="tests/basic.goose:$((lines + 3))"
if out=$("$GWEB" -C "$WORK/typo" test 2>&1); then
  bad "gweb test with a type error succeeded"
else
  case "$out" in *"$want"*) ok ;; *) bad "wanted '$want' in:"; show "$out" ;; esac
  # Instantiation traces may name the generated main; the copied test file must not appear.
  case "$out" in *".gooseweb.test/t_"*) bad "the copied test file's path leaked into the errors:"; show "$out" ;; *) ok ;; esac
fi
cp -R "$HERE/routes/site" "$WORK/name"
cp "$WORK/name/tests/basic.goose" "$WORK/name/tests/Bad-Name.goose"
want="tests/Bad-Name.goose: error: a test file's name is [a-z][a-z0-9_]*"
if out=$("$GWEB" -C "$WORK/name" test 2>&1); then
  bad "gweb test with a bad file name succeeded"
else
  case "$out" in *"$want"*) ok ;; *) bad "wanted '$want' in:"; show "$out" ;; esac
fi

# 5. .gooseweb/ is untouched.
cp -R "$HERE/routes/site" "$WORK/keep"
if "$GWEB" -C "$WORK/keep" build >/dev/null 2>&1; then
  before=$(cksum "$WORK/keep/.gooseweb/server" "$WORK/keep/.gooseweb/main.goose" "$WORK/keep/.gooseweb/map.txt")
  if "$GWEB" -C "$WORK/keep" test >/dev/null 2>&1; then ok; else bad "gweb test in the built project"; fi
  after=$(cksum "$WORK/keep/.gooseweb/server" "$WORK/keep/.gooseweb/main.goose" "$WORK/keep/.gooseweb/map.txt")
  if [ "$before" = "$after" ]; then ok; else bad "gweb test changed .gooseweb/"; fi
  if [ -x "$WORK/keep/.gooseweb/server" ]; then ok; else bad ".gooseweb/server is not executable after gweb test"; fi
  if [ -x "$WORK/keep/.gooseweb.test/routes_test" ]; then ok; else bad "no .gooseweb.test/routes_test"; fi
else
  bad "gweb build of the site"
fi

echo "routes.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
