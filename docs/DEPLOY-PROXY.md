# Deploying behind a reverse proxy

gweb speaks plain HTTP/1.1. It has no TLS and no HTTP/2. In production, run it
on loopback behind Caddy or nginx on the same host:

```
SITE_URL=https://example.com gweb start --host 127.0.0.1 --port 3000
```

(`--host` defaults to `0.0.0.0`.) The proxy ends TLS, speaks HTTP/2, and compresses
HTML and JSON.

## What the app needs

- **`SITE_URL`**: the public base URL, no trailing slash. `@meta()` and the sitemap build
  absolute URLs from it. Without it they use the `Host` header, which the client controls.
- **`GWEB_TRUST_PROXY=1`**: required. gweb reads `X-Forwarded-Proto` and `X-Forwarded-For` only when it is on.
  Without it the session and CSRF cookies are plain `gw_session` and `gw_csrf`, with no `Secure`.
- **Cookies**: set `secure: true` in `gweb::CookieOptions`. With `GWEB_TRUST_PROXY` on and `X-Forwarded-Proto: https`
  the session and CSRF cookies are already `__Host-gw_session` and `__Host-gw_csrf` with `Secure`.
- **`Host` preserved**: `gweb::websocket` refuses an `Origin` whose host differs from `Host`.
  The configs below keep it.
- **`X-Forwarded-Proto`**: sent by the proxy; read by the cookie names and `gweb::site_url`, when `GWEB_TRUST_PROXY` is on.

## Caddy (recommended)

Certificates, HTTP/2, HTTP/3, WebSockets and streaming need no extra lines.

```
example.com {
    encode zstd gzip
    reverse_proxy 127.0.0.1:3000
}
```

Caddy keeps `Host`, sets `X-Forwarded-Proto`, and has no read timeout. Check with
`caddy validate --config Caddyfile`.

## nginx

Certificates from certbot (`certbot --nginx -d example.com`). In `http { }`:

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl http2;
    server_name example.com;
    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    gzip on;
    gzip_types text/html text/css application/json application/xml image/svg+xml;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }

    # long-lived routes: SSE and WebSockets
    location /events {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_buffering off;
        proxy_read_timeout 1h;
    }
}

server {
    listen 80;
    server_name example.com;
    return 301 https://$host$request_uri;
}
```

- Use the same block for each streaming or WebSocket route (`/events`, `/ws`, ...).
- `gweb::subscribe` already sends `X-Accel-Buffering: no`, so `proxy_buffering off` is
  belt and braces for SSE. A `gweb::stream_begin` download is buffered unless you turn it off.
- The hub pings every 30 s, so `proxy_read_timeout 1h` is only a ceiling.
- Use `nginx -t` to check. On nginx 1.25.1 or later, write `http2 on;` in place of `http2` on `listen`.

## Compression

The proxy does not compress a response that already has `Content-Encoding`, so the
build-time `.gz` variants of static files go through as they are. HTML and JSON are
compressed by the proxy, not by gweb.

## Not covered

HSTS, rate limits and trusting `X-Forwarded-For` are yours to configure in the proxy.
