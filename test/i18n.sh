#!/bin/sh
# goose-web's i18n suite: the locales/ catalog compiler and the generated t:: module.
#
#   GOOSE=/path/to/goose test/i18n.sh
#
# 1. test/i18n/site is built and started; curl checks negotiation, Vary, the cookie, plurals, fallback and escaping.
# 2. The build prints a "lacks" line for the locale that leaves a key out.
# 3. Each test/i18n/fail/<case> must fail gweb build with the message in its expect file.
#
# Needs curl, and gweb built beside this folder (goose build -o gweb cli/gweb.goose).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
PORT=${PORT:-3996}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-i18n.XXXXXX")
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

URL="http://127.0.0.1:$PORT"
# req NAME PATH [curl args]: status in $WORK/NAME.status, headers (lower case) in NAME.h, body in NAME.b.
req() {
  name=$1; path=$2; shift 2
  curl -s -D "$WORK/$name.h.raw" -o "$WORK/$name.b" -w '%{http_code}' "$@" "$URL$path" > "$WORK/$name.status"
  tr -d '\r' < "$WORK/$name.h.raw" | tr 'A-Z' 'a-z' > "$WORK/$name.h"
}
# has NAME TEXT DESCRIPTION: the body of request NAME is 200 and contains TEXT.
has() {
  check "$([ "$(cat "$WORK/$1.status")" = 200 ] && grep -qF -- "$2" "$WORK/$1.b" && echo ok)" "$3: no '$2' in the body of $1"
}
lacks_text() {
  check "$(grep -qF -- "$2" "$WORK/$1.b" || echo ok)" "$3: '$2' is in the body of $1"
}

# 1. The site.
cp -R "$HERE/i18n/site" "$WORK/ok"
if out=$("$GWEB" -C "$WORK/ok" build 2>&1); then
  # 2. The lacks line.
  case "$out" in
    *"gweb: locales/de.txt lacks 1 key (falls back to en): only_en"*) ok ;;
    *) bad "the build did not print the lacks line:"; echo "$out" | sed 's/^/    /' ;;
  esac
  "$WORK/ok/.gooseweb/server" --port "$PORT" >/dev/null 2>&1 &
  PID=$!
  up=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    if curl -s -o /dev/null "$URL/"; then up=yes; break; fi
  done
  if [ -z "$up" ]; then
    bad "the server did not answer on port $PORT"
  else
    req en / 
    has en 'lang="en"' "no Accept-Language"
    has en 'Hello, Ann!' "no Accept-Language"
    req de / -H 'Accept-Language: de'
    has de 'lang="de"' "Accept-Language: de"
    has de 'Hallo, Ann!' "Accept-Language: de"
    check "$(grep -q '^vary: accept-language, cookie' "$WORK/de.h" && echo ok)" "Vary is set"
    check "$(grep -q '^vary: accept-language, cookie' "$WORK/en.h" && echo ok)" "Vary is set without Accept-Language"
    req dea / -H 'Accept-Language: de-AT,en;q=0.5'
    has dea 'Hallo, Ann!' "de-AT takes de"
    req deq / -H 'Accept-Language: fr;q=0.9, en;q=0.8'
    has deq 'Hello, Ann!' "no match falls to the default"
    req ck / -H 'Accept-Language: de' -H 'Cookie: locale=en'
    has ck 'Hello, Ann!' "the locale cookie wins"
    has ck 'lang="en"' "the locale cookie wins"

    req p1 '/?n=1'
    has p1 '1 item in your cart' "plural one"
    req p2 '/?n=2'
    has p2 '2 items in your cart' "plural other"
    req dp /?n=2 -H 'Accept-Language: de'
    has dp '2 Artikel im Warenkorb' "German plural"
    req st '/?n=5'
    has st 'Only 5 left' "an int argument"
    req dst '/?n=5' -H 'Accept-Language: de'
    has dst 'Nur noch 5 übrig' "an int argument in de"

    has en 'Only in English' "the default text"
    has de 'Only in English' "a key de lacks falls back to English"
    has en 'Use &lt;b&gt; with care' "escaping"
    lacks_text en 'Use <b>' "escaping"
    has de 'Mit &lt;b&gt; vorsichtig sein' "escaping in de"
    lacks_text de 'Mit <b>' "escaping in de"
  fi
  kill "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null
  PID=""
else
  bad "gweb build of the site"; echo "$out"
fi

# 3. Expected failures: each fail/<case> holds a project and an expect file with the message.
for d in "$HERE"/i18n/fail/*/; do
  name=$(basename "$d")
  rm -rf "$WORK/f"
  cp -R "$d" "$WORK/f"
  want=$(cat "$WORK/f/expect")
  rm -f "$WORK/f/expect"
  if out=$("$GWEB" -C "$WORK/f" build 2>&1); then
    bad "fail/$name: gweb build succeeded"
  else
    case "$out" in
      *"$want"*) ok ;;
      *) bad "fail/$name: wanted '$want', got:"; echo "$out" | sed 's/^/    /' ;;
    esac
  fi
done

echo "i18n.sh: $pass of $((pass + fail)) checks passed"
[ "$fail" -eq 0 ]
