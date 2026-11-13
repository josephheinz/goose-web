#!/bin/sh
# Moves an app from gweb v0.4 to v0.5: WEB_* environment variables are GWEB_* (WEB_SECRET is GWEB_SECRET).
# Edits .env files, systemd units, Dockerfiles, compose files and Goose sources in place; run it on a clean tree.
#
#   sh tools/migrate-v0.5.sh [DIR or FILE ...]     (default: .)
#
# Rename the variables wherever else you set them (a host's environment, CI secrets). Needs perl.
set -eu
[ $# -eq 0 ] && set -- .
find "$@" -type f \( -name '.env*' -o -name '*.service' -o -name '*.socket' -o -name 'Dockerfile*' \
  -o -name '*compose*.y*ml' -o -name '*.goose' -o -name '*.md' -o -name '*.sh' \) \
  -not -path '*/.gweb*' -not -path '*/.git/*' -print0 |
xargs -0 perl -pi -e 's/(?<![A-Z_])WEB_(SECRET|CSP|WORKERS|TRUST_PROXY|HSTS|SESSION_IDLE|SECURITY_HEADERS|SESSION_MAX)\b/GWEB_$1/g'
