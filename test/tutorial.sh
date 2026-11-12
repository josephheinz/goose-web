#!/bin/sh
# The docs tutorial app (docs/site/tutorial/notes).
#
#   GOOSE=/path/to/goose test/tutorial.sh
#
# 1. Every block of docs/site/tutorial.md under a bold `**path**` line equals
#    that file of the app; under `**path: lines changed**`, each line is a
#    line of that file.
# 2. The app builds. The server answers / (200, the title), /api/notes (JSON),
#    refuses a POST without the CSRF token (403), and takes one with it.
#
# Needs curl, python3 and awk, and gweb built beside this folder (goose build -o
# gweb cli/gweb.goose).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
APP="$ROOT/docs/site/tutorial/notes"
DOC="$ROOT/docs/site/tutorial.md"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-tutorial.XXXXXX")
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

# 1. The code blocks of the tutorial match the app.
# Writes WORK/blocks/N.txt (the block) and WORK/blocks/N.path (its label).
mkdir -p "$WORK/blocks"
awk -v dir="$WORK/blocks" '
  /^\*\*.*\*\*$/ { label = $0; sub(/^\*\*/, "", label); sub(/\*\*$/, "", label); next }
  /^```/ {
    if (inblock) { inblock = 0; close(out); label = ""; next }
    if (label != "") { n++; out = dir "/" n ".txt"; printf "%s\n", label > (dir "/" n ".path"); close(dir "/" n ".path"); printf "" > out; inblock = 1 }
    next
  }
  inblock { print > out }
' "$DOC"
for p in "$WORK"/blocks/*.path; do
  [ -e "$p" ] || { bad "tutorial.md has no labelled code blocks"; break; }
  n=${p%.path}
  label=$(cat "$p")
  case "$label" in
    *": lines changed")
      file=${label%: lines changed}
      while IFS= read -r line; do
        if grep -qxF -- "$line" "$APP/$file"; then ok; else bad "tutorial.md: '$line' is not a line of $file"; fi
      done < "$n.txt"
      ;;
    *", step "*) ;;
    *)
      if [ -f "$APP/$label" ] && cmp -s "$n.txt" "$APP/$label"; then ok; else bad "tutorial.md: block '$label' differs from the app's file"; fi
      ;;
  esac
done

# 2. Build, serve, check.
PORT=${PORT:-$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}
URL="http://127.0.0.1:$PORT"
cp -R "$APP" "$WORK/app"
if ! out=$("$GWEB" -C "$WORK/app" build 2>&1); then
  bad "gweb build of the tutorial app"
  echo "$out"
else
  ok
  "$WORK/app/.gooseweb/server" --port "$PORT" >/dev/null 2>&1 &
  PID=$!
  up=""
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    sleep 0.5
    if curl -s -o /dev/null "$URL/"; then up=yes; break; fi
  done
  if [ -z "$up" ]; then
    bad "the server did not answer on port $PORT"
  else
    JAR="$WORK/jar"
    code=$(curl -s -c "$JAR" -o "$WORK/home.b" -w '%{http_code}' "$URL/")
    if [ "$code" = 200 ]; then ok; else bad "GET /: wanted 200, got $code"; fi
    if grep -qF '<title>Notes</title>' "$WORK/home.b"; then ok; else bad "GET /: no <title>Notes</title>"; fi
    if grep -qE '/_gw/CharCount(\.[0-9a-f]{8})?\.js' "$WORK/home.b"; then ok; else bad "GET /: no CharCount script"; fi

    code=$(curl -s -o "$WORK/api.b" -w '%{http_code}' "$URL/api/notes")
    if [ "$code" = 200 ] && [ "$(cat "$WORK/api.b")" = '[]' ]; then ok; else bad "GET /api/notes: wanted 200 and [], got $code $(cat "$WORK/api.b")"; fi

    # No token: 403, and nothing is added.
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -d 'text=nope' "$URL/")
    if [ "$code" = 403 ]; then ok; else bad "POST / with no token: wanted 403, got $code"; fi
    code=$(curl -s -b "$JAR" -o /dev/null -w '%{http_code}' -X POST -d 'text=nope' "$URL/")
    if [ "$code" = 403 ]; then ok; else bad "POST / with the cookie and no field: wanted 403, got $code"; fi

    # Cookie and token: the note is added.
    token=$(awk '$6 == "gw_csrf" { print $7 }' "$JAR")
    if [ -z "$token" ]; then
      bad "no gw_csrf cookie after GET /"
    else
      code=$(curl -s -b "$JAR" -o "$WORK/post.b" -w '%{http_code}' -X POST -H 'GW-Fragment: notes' --data-urlencode "_csrf=$token" --data-urlencode 'text=first <note>' "$URL/")
      if [ "$code" = 200 ]; then ok; else bad "POST / with the token: wanted 200, got $code"; fi
      if grep -qF 'first &lt;note&gt;' "$WORK/post.b"; then ok; else bad "POST / reply does not show the escaped note"; fi
      curl -s -o "$WORK/api2.b" "$URL/api/notes"
      if grep -qF '"text":"first <note>"' "$WORK/api2.b" || grep -qF 'first' "$WORK/api2.b"; then ok; else bad "GET /api/notes after the POST: $(cat "$WORK/api2.b")"; fi
    fi
  fi
  kill "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null
  PID=""
fi

echo "tutorial.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
