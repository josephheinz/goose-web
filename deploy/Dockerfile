# syntax=docker/dockerfile:1
# Build:  docker build --build-arg GOOSE_URL=<Linux goose release tarball> -t mysite .
# Run:    docker run -d -p 3000:3000 -v mysite-data:/app/data --stop-timeout 30 mysite

FROM debian:bookworm-slim AS build
ARG GOOSE_URL
ARG GWEB_REF=v0.7.0
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
RUN GOOSE="$(cat /opt/goose.path)" gweb build

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-0 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /app --shell /usr/sbin/nologin app \
 && mkdir -p /app/data \
 && chown app:app /app/data
COPY --from=build /src/app/.gooseweb/server /app/server
WORKDIR /app
USER app
VOLUME /app/data
ENV PORT=3000 TZ=UTC GWEB_LOG_FORMAT=json
EXPOSE 3000
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s CMD ["/app/server", "--probe"]
CMD ["/app/server"]
