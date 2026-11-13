#!/bin/sh
# gweb's component suite (DESIGN-ADDENDUM-3, E5).
#
#   GOOSE=/path/to/goose test/components.sh
#
# 1. Every test/components/*.gshtml not named Fail* or Warn* goes into one project, and
#    gweb test runs its test_* functions as Goose and as JavaScript, pretty
#    and compact.
# 2. Each test/components/Fail*.gshtml, alone in a project, must fail gweb build
#    with the line its `// expect: ` comment gives.
# 2a. Each test/components/stores/Fail*.gshtml, alone in a project's stores/, must fail too.
# 2b. Each Warn*.gshtml, alone in a project, warns but builds; --strict fails it;
#    --diagnostics json prints one JSON object per line. 2c: the parity project is warning-free.
# 2d. test/components/site: a component with literal http::get and http::post urls and the route.goose that
#    answers them (Name::gw_json) builds; the server sends the JSON and /_gw/gwh.js; gweb gen writes gwh.js only
#    for a site that uses http.
# 3. gweb test leaves .gweb/ alone: the built server and main.goose keep
#    their checksums across a test run.
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

# A fixture's `// with: A B` line names components it needs beside it (test/components/A.gshtml or components/with/A.gshtml),
# or stores (test/components/stores/A.gshtml).
with_files() {
  for w in $(sed -n 's|^// with: ||p' "$1"); do
    if [ -f "$HERE/components/stores/$w.gshtml" ]; then mkdir -p "$2/stores"; cp "$HERE/components/stores/$w.gshtml" "$2/stores/";
    elif [ -f "$HERE/components/$w.gshtml" ]; then cp "$HERE/components/$w.gshtml" "$2/components/"; else cp "$HERE/components/with/$w.gshtml" "$2/components/"; fi
  done
}

# 1. Parity.
mkdir -p "$WORK/ok/app" "$WORK/ok/components"
echo '<p>components suite</p>' > "$WORK/ok/app/page.html"
for f in "$HERE"/components/*.gshtml; do
  case "$(basename "$f")" in Fail*|Warn*) ;; *) cp "$f" "$WORK/ok/components/" ;; esac
done
mkdir -p "$WORK/ok/stores"
for f in "$HERE"/components/stores/*.gshtml; do
  case "$(basename "$f")" in Fail*) ;; *) cp "$f" "$WORK/ok/stores/" ;; esac
done
if out=$("$GWEB" -C "$WORK/ok" test 2>&1); then ok; echo "$out"; else bad "gweb test"; echo "$out"; fi

# 2. Expected failures.
for f in "$HERE"/components/Fail*.gshtml; do
  name=$(basename "$f")
  expect=$(sed -n 's|^// expect: ||p' "$f")
  dir="$WORK/${name%.gshtml}"
  mkdir -p "$dir/app" "$dir/components"
  echo '<p>x</p>' > "$dir/app/page.html"
  cp "$f" "$dir/components/"
  with_files "$f" "$dir"
  if out=$("$GWEB" -C "$dir" build 2>&1); then
    bad "$name: gweb build succeeded"
  else
    case "$out" in
      *"$expect"*) ok ;;
      *) bad "$name: wanted '$expect', got:"; echo "$out" | sed 's/^/    /' ;;
    esac
  fi
done

# 2a. Each stores/Fail*.gshtml, alone in a project's stores/ (a store has no `// with:`), must fail too.
for f in "$HERE"/components/stores/Fail*.gshtml; do
  name=$(basename "$f")
  expect=$(sed -n 's|^// expect: ||p' "$f")
  dir="$WORK/s${name%.gshtml}"
  mkdir -p "$dir/app" "$dir/stores"
  echo '<p>x</p>' > "$dir/app/page.html"
  cp "$f" "$dir/stores/"
  if out=$("$GWEB" -C "$dir" build 2>&1); then
    bad "stores/$name: gweb build succeeded"
  else
    case "$out" in
      *"$expect"*) ok ;;
      *) bad "stores/$name: wanted '$expect', got:"; echo "$out" | sed 's/^/    /' ;;
    esac
  fi
done

# 2b. Each Warn*.gshtml, alone in a project, builds with its `// warn: ` line on stderr;
# --strict fails it; --diagnostics json prints JSON Lines, one with code unkeyed-for.
for f in "$HERE"/components/Warn*.gshtml; do
  name=$(basename "$f")
  want=$(sed -n 's|^// warn: ||p' "$f")
  code=$(sed -n 's|^// code: ||p' "$f")
  [ -n "$code" ] || code=unkeyed-for
  dir="$WORK/${name%.gshtml}"
  mkdir -p "$dir/app" "$dir/components"
  echo '<p>x</p>' > "$dir/app/page.html"
  cp "$f" "$dir/components/"
  with_files "$f" "$dir"
  if out=$("$GWEB" -C "$dir" build 2>&1 >/dev/null); then
    case "$out" in *"$want"*) ok ;; *) bad "$name: wanted '$want', got:"; echo "$out" | sed 's/^/    /' ;; esac
  else
    bad "$name: gweb build failed on a warning"; echo "$out" | sed 's/^/    /'
  fi
  if "$GWEB" -C "$dir" build --strict >/dev/null 2>&1; then bad "$name: gweb build --strict succeeded"; else ok; fi
  "$GWEB" -C "$dir" build --diagnostics json >/dev/null 2>"$WORK/diag.jsonl"
  if node -e '
    const ls = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
    let hit = false;
    for (const l of ls) {
      const o = JSON.parse(l);
      for (const k of ["severity", "file", "line", "code", "message"]) if (!(k in o)) throw new Error("no " + k);
      if (o.code === process.argv[2]) hit = true;
    }
    process.exit(hit ? 0 : 1);
  ' "$WORK/diag.jsonl" "$code"; then ok; else bad "$name: --diagnostics json"; sed 's/^/    /' "$WORK/diag.jsonl"; fi
done

# 2c. The parity project builds clean under --strict.
if out=$("$GWEB" -C "$WORK/ok" build --strict 2>&1); then ok; else bad "parity project: gweb build --strict"; echo "$out" | sed 's/^/    /'; fi

# 2d. Typed fetch against real routes.
cp -R "$HERE/components/site" "$WORK/site"
if out=$("$GWEB" -C "$WORK/site" build --strict 2>&1); then
  ok
  PORT=${PORT:-$((4000 + $$ % 900))}
  "$WORK/site/.gweb/server" --port "$PORT" >/dev/null 2>&1 &
  SPID=$!
  up=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    if curl -s -o /dev/null "http://127.0.0.1:$PORT/"; then up=yes; break; fi
  done
  if [ -n "$up" ]; then
    body=$(curl -s "http://127.0.0.1:$PORT/api/items")
    if [ "$body" = '[{"id":1,"title":"one"},{"id":2,"title":"t\"wo"}]' ]; then ok; else bad "site: GET /api/items answered $body"; fi
    if curl -s "http://127.0.0.1:$PORT/_gw/gwh.js" | grep -q 'X-CSRF-Token'; then ok; else bad "site: /_gw/gwh.js is not served"; fi
  else
    bad "site: the server did not start"
  fi
  { kill "$SPID"; wait "$SPID"; } 2>/dev/null
else
  bad "site: gweb build"; echo "$out" | sed 's/^/    /'
fi
mkdir -p "$WORK/nohttp"
cp -R "$WORK/ok/app" "$WORK/ok/components" "$WORK/ok/stores" "$WORK/nohttp/"
rm "$WORK/nohttp/components/RFetch.gshtml"
rm "$WORK/nohttp/components/RClockAsync.gshtml"
if "$GWEB" -C "$WORK/nohttp" gen >/dev/null 2>&1; then
  if [ -e "$WORK/nohttp/.gweb/_gw/gwh.js" ]; then bad "gwh.js was written for a site without http"; else ok; fi
else
  bad "gweb gen without RFetch"
fi

# gwl.js is written only for a site with lifecycle blocks or watches.
mkdir -p "$WORK/nolife"
cp -R "$WORK/nohttp/app" "$WORK/nohttp/components" "$WORK/nohttp/stores" "$WORK/nolife/"
rm "$WORK/nolife/components/RClock.gshtml" "$WORK/nolife/components/RWatch.gshtml" "$WORK/nolife/components/RCartBadge.gshtml" "$WORK/nolife/components/RCartButton.gshtml"
if "$GWEB" -C "$WORK/nolife" gen >/dev/null 2>&1; then
  if [ -e "$WORK/nolife/.gweb/_gw/gwl.js" ]; then bad "gwl.js was written for a site without lifecycle"; else ok; fi
else
  bad "gweb gen without RClock"
fi
if [ -e "$WORK/nohttp/.gweb/_gw/gwl.js" ]; then ok; else bad "gwl.js is not written for a site with lifecycle"; fi

# gwc.js is written only for a site where a component calls a child.
mkdir -p "$WORK/nokids"
cp -R "$WORK/nolife/app" "$WORK/nolife/components" "$WORK/nolife/stores" "$WORK/nokids/"
rm "$WORK/nokids/components/RNest.gshtml" "$WORK/nokids/components/RNestEvent.gshtml"
if "$GWEB" -C "$WORK/nokids" gen >/dev/null 2>&1; then
  if [ -e "$WORK/nokids/.gweb/_gw/gwc.js" ]; then bad "gwc.js was written for a site without child components"; else ok; fi
else
  bad "gweb gen without RNest"
fi
if [ -e "$WORK/nolife/.gweb/_gw/gwc.js" ]; then ok; else bad "gwc.js is not written for a site with child components"; fi

# gws.js is written only for a site that has a store; a store is served as /_gw/Name.js.
mkdir -p "$WORK/nostores"
cp -R "$WORK/nokids/app" "$WORK/nokids/components" "$WORK/nostores/"
rm "$WORK/nostores/components/RCartBadge.gshtml" "$WORK/nostores/components/RCartButton.gshtml" 2>/dev/null
if "$GWEB" -C "$WORK/nostores" gen >/dev/null 2>&1; then
  if [ -e "$WORK/nostores/.gweb/_gw/gws.js" ]; then bad "gws.js was written for a site without stores"; else ok; fi
else
  bad "gweb gen without stores"
fi
if [ -e "$WORK/nokids/.gweb/_gw/gws.js" ] && [ -e "$WORK/nokids/.gweb/_gw/RCart.js" ]; then ok; else bad "gws.js and RCart.js are not written for a site with a store"; fi

# A store and a component cannot share a name.
mkdir -p "$WORK/samename/app" "$WORK/samename/stores" "$WORK/samename/components"
echo '<p>x</p>' > "$WORK/samename/app/page.html"
cp "$HERE/components/stores/RCart.gshtml" "$WORK/samename/stores/"
printf '<script goose>\n@state var n: i64 = 0;\n</script>\n<p>{n}</p>\n' > "$WORK/samename/components/RCart.gshtml"
if out=$("$GWEB" -C "$WORK/samename" build 2>&1); then bad "a store and a component with one name built"; else
  case "$out" in *"stores/RCart.gshtml: error: a store and a component cannot have the same name"*) ok ;; *) bad "same name: got $out" ;; esac
fi

# 3. gweb test leaves .gweb/ alone.
mkdir -p "$WORK/keep"
cp -R "$WORK/ok/app" "$WORK/ok/components" "$WORK/ok/stores" "$WORK/keep/"
if "$GWEB" -C "$WORK/keep" test >/dev/null 2>&1; then
  if [ -e "$WORK/keep/.gweb" ]; then bad "gweb test created .gweb/"; else ok; fi
  if [ -x "$WORK/keep/.gweb.test/parity/components_test" ]; then ok; else bad "gweb test did not write .gweb.test/parity/components_test"; fi
else
  bad "gweb test in a project with no .gweb/"
fi
if "$GWEB" -C "$WORK/keep" build >/dev/null 2>&1; then
  before=$(cksum "$WORK/keep/.gweb/server" "$WORK/keep/.gweb/main.goose")
  if "$GWEB" -C "$WORK/keep" test >/dev/null 2>&1; then ok; else bad "second gweb test"; fi
  after=$(cksum "$WORK/keep/.gweb/server" "$WORK/keep/.gweb/main.goose")
  if [ "$before" = "$after" ]; then ok; else bad "gweb test changed .gweb/server or main.goose"; fi
  if [ -x "$WORK/keep/.gweb/server" ]; then ok; else bad ".gweb/server is not executable after gweb test"; fi
else
  bad "gweb build in the keep project"
fi

echo "components.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
