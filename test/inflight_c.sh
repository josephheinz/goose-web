#!/bin/sh
# Builds src/inflight.c against a stub goose.h and runs the in-flight table tests.
set -e
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cc -std=gnu11 -Wall -Wextra -Wno-unused-parameter -g -Itest/stub -o "$out/inflight_c_test" test/inflight_c_test.c src/inflight.c
"$out/inflight_c_test"
