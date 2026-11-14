# syntax=docker/dockerfile:1
# Build:  docker build --build-arg GOOSE_URL=<Linux goose release tarball> -t mysite .
# Run:    docker run -d -p 3000:3000 -v mysite-data:/app/data --stop-timeout 30 mysite
# C libraries: goose-blob (libcurl) and goose-postgres (libpq) in the generated root add theirs; name others with
# --build-arg APT_BUILD="libfoo-dev" (build stage) and APT_RUN="libfoo1" (runtime).

FROM debian:bookworm-slim AS build
ARG GOOSE_URL
ARG APT_BUILD=""
ARG APT_RUN=""
ARG GWEB_REF=v1.2.0
ARG GWEB_REPO=https://github.com/josephheinz/gweb
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc libc6-dev libsqlite3-dev git ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
    [ -n "$GOOSE_URL" ] || { echo "GOOSE_URL is required: docker build --build-arg GOOSE_URL=<Linux goose tarball URL> ." >&2; exit 1; }; \
    mkdir /opt/goose; \
    curl -fsSL "$GOOSE_URL" | tar -xz -C /opt/goose; \
    found=$(find /opt/goose -type f -name goose | head -n 1); \
    [ -n "$found" ] || { echo "no goose binary in $GOOSE_URL" >&2; exit 1; }; \
    echo "$found" > /opt/goose.path
RUN set -eu; \
    git clone --depth 1 --branch "$GWEB_REF" "$GWEB_REPO" /opt/gweb; \
    cd /opt/gweb; \
    "$(cat /opt/goose.path)" build -o gweb cli/gweb.goose; \
    cp gweb /usr/local/bin/gweb
COPY . /src/app
WORKDIR /src/app
RUN set -eu; \
    GOOSE="$(cat /opt/goose.path)" gweb gen; \
    build="$APT_BUILD"; run="$APT_RUN"; \
    if grep -q '^import [A-Za-z0-9_]* from ".*goose-blob' .gweb/main.goose; then build="$build libcurl4-openssl-dev"; run="$run libcurl4 ca-certificates"; fi; \
    if grep -q '^import [A-Za-z0-9_]* from ".*goose-postgres' .gweb/main.goose; then build="$build libpq-dev"; run="$run libpq5"; fi; \
    echo "$run" > /opt/apt-run; \
    if [ -n "$(echo $build)" ]; then \
      apt-get update; \
      apt-get install -y --no-install-recommends $build; \
      rm -rf /var/lib/apt/lists/*; \
    fi
RUN GOOSE="$(cat /opt/goose.path)" gweb build

FROM debian:bookworm-slim
COPY --from=build /opt/apt-run /opt/apt-run
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-0 $(cat /opt/apt-run) \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /app --shell /usr/sbin/nologin app \
 && mkdir -p /app/data \
 && chown app:app /app/data
COPY --from=build /src/app/.gweb/server /app/server
WORKDIR /app
USER app
VOLUME /app/data
ENV PORT=3000 TZ=UTC GWEB_LOG_FORMAT=json
EXPOSE 3000
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s CMD ["/app/server", "--probe"]
CMD ["/app/server"]
