#!/bin/sh
# Builds src/upload.c against a stub goose.h and runs the file-helper tests.
set -e
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cc -std=gnu11 -Wall -Wextra -Wno-unused-parameter -g -Itest/stub -o "$out/upload_c_test" test/upload_c_test.c src/upload.c
"$out/upload_c_test"
