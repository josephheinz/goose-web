#!/bin/sh
# Runs the whole test set on Linux (Debian bookworm, glibc) and checks the app Docker image.
#
#   GOOSE_URL=<Linux goose release tarball> test/linux.sh
#
# 1. Copies gweb, goose-net and goose-sqlite into a container, builds gweb, runs the C tests of both
#    repos, the Goose tests and every suite (components, templates, fragments, catchall, morph, ops).
# 2. Builds a starter site with deploy/Dockerfile (gweb and the packages come from local git
#    repos, not GitHub), starts it, waits for the HEALTHCHECK, and stops it with SIGTERM.
#
# Needs docker, git and curl on this machine. The sibling repos are ../goose-net and ../goose-sqlite
# (or GOOSE_NET_DIR and GOOSE_SQLITE_DIR). PORT (default 3980) is the host port of step 2.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
LAB=$(dirname "$ROOT")
NET_DIR=${GOOSE_NET_DIR:-$LAB/goose-net}
SQLITE_DIR=${GOOSE_SQLITE_DIR:-$LAB/goose-sqlite}
PORT=${PORT:-3980}

if [ -z "${GOOSE_URL:-}" ]; then
  echo "linux.sh: set GOOSE_URL to a Linux goose release tarball" >&2
  exit 2
fi
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "linux.sh: docker is missing or not running" >&2
  exit 2
fi
for d in "$NET_DIR" "$SQLITE_DIR"; do
  [ -d "$d" ] || { echo "linux.sh: $d is missing (set GOOSE_NET_DIR or GOOSE_SQLITE_DIR)" >&2; exit 2; }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-linux.XXXXXX")
TAG=gweb-linux-$$
CNAME=$TAG-run
APP=$TAG-app
cleanup() {
  docker rm -f "$CNAME" "$CNAME-app" >/dev/null 2>&1 || true
  docker rmi -f "$TAG" "$APP" "$APP-x" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# Tracked and untracked files only: no host build output, no .git.
copy_repo() {
  mkdir -p "$2"
  (cd "$1" && git ls-files -co --exclude-standard -z | tar -c --null -T -) | tar -x -C "$2"
}
mkdir -p "$WORK/ctx"
copy_repo "$ROOT" "$WORK/ctx/gweb"
copy_repo "$NET_DIR" "$WORK/ctx/goose-net"
copy_repo "$SQLITE_DIR" "$WORK/ctx/goose-sqlite"

cat > "$WORK/ctx/Dockerfile" <<'EOF'
FROM debian:bookworm-slim
ARG GOOSE_URL
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc libc6-dev libsqlite3-dev git ca-certificates curl python3 nodejs npm \
 && rm -rf /var/lib/apt/lists/*
RUN set -eu; mkdir /opt/goose; curl -fsSL "$GOOSE_URL" | tar -xz -C /opt/goose; \
    found=$(find /opt/goose -type f -name goose | head -n 1); \
    [ -n "$found" ] || { echo "no goose binary in the tarball" >&2; exit 1; }; \
    echo "$found" > /opt/goose.path
COPY . /lab
COPY inner.sh /inner.sh
EOF

# Runs in the container. A failing step does not stop the others.
cat > "$WORK/ctx/inner.sh" <<'EOF'
#!/bin/sh
set -u
GOOSE=$(cat /opt/goose.path)
export GOOSE
failed=0
step() {
  name=$1; shift
  if "$@" > /tmp/step.out 2>&1; then
    echo "ok   $name: $(tail -n 1 /tmp/step.out)"
  else
    echo "FAIL $name"; tail -n 30 /tmp/step.out; failed=1
  fi
}
goose_test() {   # dir file
  (cd "$1" && "$GOOSE" build -o "/tmp/$2" "test/$2.goose" && "/tmp/$2")
}
echo "== $(uname -sm), $(cc --version | head -n 1), $(ldd --version 2>&1 | head -n 1)"
cd /lab/gweb
step "gweb build" "$GOOSE" build -o gweb cli/gweb.goose
step "C tests (goose-net)" sh -c 'cd /lab/goose-net && sh test/c/run.sh'
step "C tests (gweb)" sh -c 'cd /lab/gweb && sh test/c/run.sh'
step test_net goose_test /lab/goose-net test_net
step test_sqlite goose_test /lab/goose-sqlite test_sqlite
for t in owner_test cookie_test csrf_test catchall_test; do
  step "$t" goose_test /lab/gweb "$t"
done
step components sh test/components.sh
step templates sh test/templates.sh
step fragments env PORT=3991 sh test/fragments.sh
step catchall env PORT=3994 sh test/catchall.sh
step morph sh test/morph.sh
if [ -f test/ops.sh ]; then step ops env PORT=3996 sh test/ops.sh; else echo "SKIP ops: test/ops.sh is not in this checkout"; fi
step "gweb new" ./gweb new /lab/site
if [ "$failed" -eq 0 ]; then echo "linux.sh: container suites passed"; else echo "linux.sh: container suites FAILED"; fi
exit "$failed"
EOF

echo "linux.sh: building the test image"
docker build -q --build-arg "GOOSE_URL=$GOOSE_URL" -t "$TAG" "$WORK/ctx" >/dev/null

status=0
docker run --name "$CNAME" "$TAG" sh /inner.sh || status=1

if ! docker cp "$CNAME:/lab/site" "$WORK/site" 2>/dev/null; then
  echo "linux.sh: no starter site to build an image from"
  exit 1
fi

# Step 2: the app image. The Dockerfile clones from GitHub, so give it local bare repos and the
# GWEB_* sources instead, in the build stage only.
VERSION=$(tr -d '[:space:]' < "$ROOT/VERSION")
mkdir -p "$WORK/site/_repos"
for name in gweb goose-net goose-sqlite; do
  (
    cd "$WORK/ctx/$name"
    git init -q -b main
    git add -A
    git -c user.name=linux_sh -c user.email=linux_sh@localhost commit -q -m rehearsal
    git tag "v$VERSION"
  )
  git clone -q --bare "$WORK/ctx/$name" "$WORK/site/_repos/$name.git"
done
[ -f "$WORK/site/Dockerfile" ] || cp "$ROOT/deploy/Dockerfile" "$WORK/site/Dockerfile"
[ -f "$WORK/site/.dockerignore" ] || cp "$ROOT/deploy/dockerignore" "$WORK/site/.dockerignore"
awk '{ print } /^FROM .* AS build$/ {
  print "COPY _repos /repos"
  print "ENV GWEB_SRC=file:///repos/gweb.git@v'"$VERSION"' GWEB_NET=file:///repos/goose-net.git@v'"$VERSION"' GWEB_SQLITE=file:///repos/goose-sqlite.git@v'"$VERSION"'"
}' "$WORK/site/Dockerfile" > "$WORK/site/Dockerfile.test"

echo "linux.sh: building the app image"
if ! docker build -f "$WORK/site/Dockerfile.test" --build-arg "GOOSE_URL=$GOOSE_URL" \
      --build-arg "GWEB_REF=v$VERSION" --build-arg "GWEB_REPO=file:///repos/gweb.git" \
      -t "$APP" "$WORK/site" >"$WORK/image.out" 2>&1; then
  echo "FAIL app image build"; tail -n 30 "$WORK/image.out"; exit 1
fi
echo "ok   app image built"

# The empty-GOOSE_URL message.
if docker build -f "$WORK/site/Dockerfile.test" --build-arg GOOSE_URL= -t "$APP-x" "$WORK/site" >"$WORK/empty.out" 2>&1; then
  echo "FAIL a build with an empty GOOSE_URL succeeded"; status=1
elif grep -q "GOOSE_URL is required" "$WORK/empty.out"; then
  echo "ok   an empty GOOSE_URL stops the build with a message"
else
  echo "FAIL an empty GOOSE_URL gave no clear message"; tail -n 10 "$WORK/empty.out"; status=1
fi

docker run -d --name "$CNAME-app" -p "127.0.0.1:$PORT:3000" "$APP" >/dev/null
health=""
for i in $(seq 1 30); do
  health=$(docker inspect -f '{{.State.Health.Status}}' "$CNAME-app" 2>/dev/null || true)
  [ "$health" = healthy ] && break
  sleep 1
done
if [ "$health" = healthy ]; then echo "ok   HEALTHCHECK (server --probe) reports healthy"
else echo "FAIL HEALTHCHECK is '$health'"; docker logs "$CNAME-app" 2>&1 | tail -n 20; status=1; fi

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/__gweb/ready" || true)
[ "$code" = 200 ] && echo "ok   /__gweb/ready answers 200" || { echo "FAIL /__gweb/ready answered '$code'"; status=1; }
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" || true)
[ "$code" = 200 ] && echo "ok   / answers 200" || { echo "FAIL / answered '$code'"; status=1; }

user=$(docker exec "$CNAME-app" id -u 2>/dev/null || true)
[ "$user" = 10001 ] && echo "ok   runs as uid 10001" || { echo "FAIL runs as uid '$user'"; status=1; }

docker stop -t 30 "$CNAME-app" >/dev/null
exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$CNAME-app")
[ "$exit_code" = 0 ] && echo "ok   SIGTERM as PID 1 exits 0" || { echo "FAIL exit code $exit_code after docker stop"; status=1; }

[ "$status" -eq 0 ] && echo "linux.sh: all passed" || echo "linux.sh: FAILED"
exit "$status"
