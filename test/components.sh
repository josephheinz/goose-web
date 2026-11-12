#!/bin/sh
# goose-web's component suite (DESIGN-ADDENDUM-3, E5).
#
#   GOOSE=/path/to/goose test/components.sh
#
# 1. client/gwi.min.js must carry the FNV-1a hash of client/gwi.js in its
#    banner (client/build.sh writes it), so a stale minified runtime fails.
# 2. Every test/components/*.gshtml not named Fail* goes into one project, and
#    gweb test runs its test_* functions as Goose and as JavaScript, pretty
#    and compact.
# 3. Each test/components/Fail*.gshtml, alone in a project, must fail gweb build
#    with the line its `// expect: ` comment gives.
#
# Needs node, and gweb built beside this folder (goose build -o gweb cli/gweb.goose).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-components.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# 1. The minified runtime is current.
want=$(node "$ROOT/client/fnv.mjs" "$ROOT/client/gwi.js")
have=$(head -c 40 "$ROOT/client/gwi.min.js" | sed -n 's|^/\* gwi \([0-9a-f]*\) \*/.*|\1|p')
if [ "$want" = "$have" ]; then ok; else bad "client/gwi.min.js is stale (banner '$have', gwi.js hashes to $want): run client/build.sh"; fi

# 2. Parity.
mkdir -p "$WORK/ok/app" "$WORK/ok/components"
echo '<p>components suite</p>' > "$WORK/ok/app/page.html"
for f in "$HERE"/components/*.gshtml; do
  case "$(basename "$f")" in Fail*) ;; *) cp "$f" "$WORK/ok/components/" ;; esac
done
if out=$("$GWEB" -C "$WORK/ok" test 2>&1); then ok; echo "$out"; else bad "gweb test"; echo "$out"; fi

# 3. Expected failures.
for f in "$HERE"/components/Fail*.gshtml; do
  name=$(basename "$f")
  expect=$(sed -n 's|^// expect: ||p' "$f")
  dir="$WORK/${name%.gshtml}"
  mkdir -p "$dir/app" "$dir/components"
  echo '<p>x</p>' > "$dir/app/page.html"
  cp "$f" "$dir/components/"
  if out=$("$GWEB" -C "$dir" build 2>&1); then
    bad "$name: gweb build succeeded"
  else
    case "$out" in
      *"$expect"*) ok ;;
      *) bad "$name: wanted '$expect', got:"; echo "$out" | sed 's/^/    /' ;;
    esac
  fi
done

echo "components.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
