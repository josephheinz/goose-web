#!/bin/sh
# gweb's views suite (DESIGN-ADDENDUM-19, D1 and D2).
#
#   GOOSE=/path/to/goose test/views.sh
#
# 1. test/views/site is built, and gweb test runs tests/views.goose: the registry, ViewMeta, rendering by name through
#    @slot zones, the lenient JSON codec, RENAMED, the generated form and form parser.
# 2. A package's views/ joins the project's (test/views/pkg); the same name in both is an error.
# 3. Each build error, in a copy of the site, must fail gweb gen with its message at its path.
# 4. The generated files keep the user's line numbers.
#
# Needs gweb built beside this folder (goose build -o gweb cli/gweb.goose). Starts no server.
set -u
PORT=${PORT:-4106}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-views.XXXXXX")
PID=""
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$WORK"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { if [ "$1" = ok ]; then ok; else bad "$2"; fi; }
show() { echo "$1" | sed 's/^/    /'; }

# 1. The site.
cp -R "$HERE/views/site" "$WORK/ok"
if out=$("$GWEB" -C "$WORK/ok" test 2>&1); then
  case "$out" in *"routes: 8 tests, "*" 0 failed"*) ok ;; *) bad "gweb test did not print 'routes: 8 tests ... 0 failed':"; show "$out" ;; esac
else
  bad "gweb test of the views site failed:"; show "$out"
fi
if out=$("$GWEB" -C "$WORK/ok" build 2>&1); then ok; else bad "gweb build of the views site"; show "$out"; fi

# 4. Line numbers: the generated file starts with the user's lines.
gen=$(sed -n '1p' "$WORK/ok/.gweb/v_widgets_Hero.goose")
want=$(sed -n '1p' "$HERE/views/site/views/widgets/Hero.goose")
case "$gen" in *"$want") ok ;; *) bad "line 1 of v_widgets_Hero.goose is the user's line 1 after the namespace prefix: '$gen'" ;; esac
n=$(wc -l < "$HERE/views/site/views/widgets/Hero.goose" | tr -d ' ')
check "$([ "$(sed -n "$((n + 2)),\$p" "$WORK/ok/.gweb/v_widgets_Hero.goose" | head -n 1)" = "// gweb: view codec, form and parser (generated)" ] && echo ok)" "the generated code follows the user's last line"
check "$(grep -q 'v_widgets_Hero.goose	views/widgets/Hero.goose' "$WORK/ok/.gweb/map.txt" && grep -q 'v_widgets_Hero_html.goose	views/widgets/Hero.html' "$WORK/ok/.gweb/map.txt" && echo ok)" "map.txt maps the generated files to the sources"

# 2. A package's views.
rm -rf "$WORK/pk"
mkdir -p "$WORK/pk"
cp -R "$HERE/views/site" "$WORK/pk/app"
cp -R "$HERE/views/pkg" "$WORK/pk/pkg"
printf '../pkg\n' > "$WORK/pk/app/gweb.packages"
rm "$WORK/pk/app/tests/views.goose"
cp "$HERE/views/pkg_test.goose" "$WORK/pk/app/tests/pkg.goose"
if out=$("$GWEB" -C "$WORK/pk/app" test 2>&1); then
  case "$out" in *"ok t_pkg::test_package_view"*) ok ;; *) bad "the package view is not in the registry:"; show "$out" ;; esac
else
  bad "gweb test with a package that has views/ failed:"; show "$out"
fi
mkdir -p "$WORK/pk/app/views/widgets"
cp "$HERE/views/pkg/views/widgets/Banner.goose" "$HERE/views/pkg/views/widgets/Banner.html" "$WORK/pk/app/views/widgets/"
if out=$("$GWEB" -C "$WORK/pk/app" gen 2>&1); then
  bad "a view defined by the project and a package: gweb gen succeeded"
else
  case "$out" in *"is also defined in "*"; a view's name is unique in its group"*) ok ;; *) bad "wanted the duplicate view error, got:"; show "$out" ;; esac
fi

# 3. Errors. expect_fail MESSAGE PATH SETUP: SETUP runs in a copy of the site; gweb gen must say PATH: error: MESSAGE.
expect_fail() {
  msg=$1; where=$2; setup=$3
  rm -rf "$WORK/f"
  cp -R "$HERE/views/site" "$WORK/f"
  (cd "$WORK/f" && eval "$setup")
  want="$where: error: $msg"
  if out=$("$GWEB" -C "$WORK/f" gen 2>&1); then
    bad "'$where': gweb gen succeeded"
  else
    case "$out" in
      *"$want"*) ok ;;
      *) bad "wanted '$want', got:"; show "$out" ;;
    esac
  fi
}

expect_fail "a view needs both files: views/widgets/Lone.html is missing" views/widgets/Lone.goose \
  'echo "struct Props { a: i64 }" > views/widgets/Lone.goose'
expect_fail "a view needs both files: views/widgets/Lone.goose is missing" views/widgets/Lone.html \
  'echo "<p></p>" > views/widgets/Lone.html'
expect_fail "a view's name is [A-Z][A-Za-z0-9]*, as in views/widgets/Hero.goose" views/widgets/lower.goose \
  'echo "struct Props { a: i64 }" > views/widgets/lower.goose; echo "<p></p>" > views/widgets/lower.html'
expect_fail "a views group is [a-z][a-z0-9_]*, as in views/widgets/" views/Bad \
  'mkdir views/Bad'
expect_fail "a view needs \`struct Props {\` in its .goose file" views/widgets/NoProps.goose \
  'echo "import std;" > views/widgets/NoProps.goose; echo "<p></p>" > views/widgets/NoProps.html'
expect_fail "f64 is not a type views know: Props fields are i64, bool, u8[..N], an enum without payloads, a struct of this file, a repeater of one (last) or ns::T" views/widgets/F.goose:1 \
  'echo "struct Props { a: f64 }" > views/widgets/F.goose; echo "<p></p>" > views/widgets/F.html'
expect_fail "a text field is u8[..N] with N a number above 0" views/widgets/F.goose:2 \
  'printf "const N = 5;\\nstruct Props { a: u8[..N] }\\n" > views/widgets/F.goose; echo "<p></p>" > views/widgets/F.html'
expect_fail "enum E: a view's enum has variants with no payload, as in { Light, Dark }" views/widgets/F.goose:1 \
  'printf "enum E { A, B { x: i64 } }\nstruct Props { a: E }\n" > views/widgets/F.goose; echo "<p></p>" > views/widgets/F.html'
expect_fail "a repeater (T[>..<]) is the last field of Props" views/widgets/F.goose:3 \
  'printf "struct I { a: i64 }\nstruct Props {\n    l: I[>..<],\n    b: i64,\n}\n" > views/widgets/F.goose; echo "<p></p>" > views/widgets/F.html'
expect_fail "a repeater's items hold no repeater" views/widgets/F.goose:1 \
  'printf "struct I { l: I[>..<] }\nstruct Props { l: I[>..<] }\n" > views/widgets/F.goose; echo "<p></p>" > views/widgets/F.html'
expect_fail "UI: field \"nope\" is not a field of Props" views/widgets/F.goose:1 \
  'printf "let UI = [gweb::FieldUi { field: \"nope\", label: \"x\" }];\nstruct Props { a: i64 = 0 }\n" > views/widgets/F.goose; echo "<p></p>" > views/widgets/F.html'
expect_fail "ENUM_LABELS: E.C is not a variant of an enum of this view's fields" views/widgets/F.goose:2 \
  'printf "enum E { A, B }\nlet ENUM_LABELS = [gweb::EnumLabel { ty: \"E\", variant: \"C\", label: \"x\" }];\nstruct Props { a: E = E.A }\n" > views/widgets/F.goose; echo "<p></p>" > views/widgets/F.html'
expect_fail "each gweb::EnumLabel needs ty, variant and label (string literals only)" views/widgets/F.goose:2 \
  'printf "enum E { A, B }\nlet ENUM_LABELS = [gweb::EnumLabel { ty: \"E\", variant: \"A\" }];\nstruct Props { a: E = E.A }\n" > views/widgets/F.goose; echo "<p></p>" > views/widgets/F.html'
expect_fail "fn read is generated for every view; rename yours" views/widgets/F.goose:2 \
  'printf "struct Props { a: i64 = 0 }\nfn read(a: i64) {}\n" > views/widgets/F.goose; echo "<p></p>" > views/widgets/F.html'
expect_fail "@slot(\"name\") or @slot(\"name\", \"View1 View2\"): string literals, the name [a-z][a-z0-9_-]*" views/widgets/F.html:1 \
  'echo "struct Props { a: i64 = 0 }" > views/widgets/F.goose; echo "<p>@slot(x)</p>" > views/widgets/F.html'
expect_fail "@slot(\"name\") or @slot(\"name\", \"View1 View2\"): string literals, the name [a-z][a-z0-9_-]*" views/widgets/F.html:1 \
  'echo "struct Props { a: i64 = 0 }" > views/widgets/F.goose; echo "<p>@slot()</p>" > views/widgets/F.html'
expect_fail "two slots named a" views/widgets/F.html:1 \
  'echo "struct Props { a: i64 = 0 }" > views/widgets/F.goose; echo "<p>@slot(\"a\")@slot(\"a\")</p>" > views/widgets/F.html'
expect_fail "@slot() is for layout.html only" app/page.html:1 \
  'echo "<p>@slot(\"a\")</p>" > app/page.html'

# 5. gweb::reserved_prefixes() (D4): test/views/reserved has routes, a root catch-all and public files.
cp -R "$HERE/views/reserved" "$WORK/rp"
if out=$("$GWEB" -C "$WORK/rp" test 2>&1); then
  case "$out" in *"ok t_reserved::test_reserved_prefixes"*) ok ;; *) bad "reserved_prefixes test did not run:"; show "$out" ;; esac
else
  bad "gweb test of the reserved prefixes failed:"; show "$out"
fi

# 6. A state Msg with a variable-size payload (const VARIABLE_MSG = true;, E4): 250,000 bytes through the owner, twice.
cp -R "$HERE/views/bigmsg" "$WORK/bm"
if out=$("$GWEB" -C "$WORK/bm" test 2>&1); then
  case "$out" in *"ok t_save::test_variable_message"*) ok ;; *) bad "variable Msg in gweb test:"; show "$out" ;; esac
else
  bad "gweb test of the variable Msg site failed:"; show "$out"
fi
if out=$("$GWEB" -C "$WORK/bm" build 2>&1); then
  "$WORK/bm/.gweb/server" --port "$PORT" >/dev/null 2>&1 &
  PID=$!
  up=""
  for i in 1 2 3 4 5 6 7 8 9 10; do sleep 0.5; if curl -s -o /dev/null "http://127.0.0.1:$PORT/"; then up=1; break; fi; done
  if [ -z "$up" ]; then bad "the variable Msg server did not answer on port $PORT"; else
    head -c 250000 /dev/zero | tr '\0' a > "$WORK/big.txt"
    r1=$(curl -s -X POST --data-binary @"$WORK/big.txt" -H 'Content-Type: text/plain' "http://127.0.0.1:$PORT/save")
    r2=$(curl -s -X POST --data-binary @"$WORK/big.txt" -H 'Content-Type: text/plain' "http://127.0.0.1:$PORT/save")
    check "$([ "$r1" = "ok=true n=250000 total=250000 saves=1" ] && [ "$r2" = "ok=true n=250000 total=500000 saves=2" ] && echo ok)" "250,000 bytes through the owner twice: '$r1' '$r2'"
  fi
  kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""
else
  bad "gweb build of the variable Msg site"; show "$out"
fi

echo "views.sh: $pass of $((pass + fail)) checks passed"
[ "$fail" -eq 0 ]
