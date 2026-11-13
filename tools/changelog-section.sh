#!/bin/sh
# Prints one version's section of CHANGELOG.md, without its heading: sh tools/changelog-section.sh v0.5.0
set -eu
v=${1#v}
awk -v h="## v$v" '$0 == h { on = 1; next } on && /^## / { exit } on { print }' "${2:-CHANGELOG.md}"
