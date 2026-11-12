#!/bin/sh
# Builds and runs every test listed in test/c/tests.conf. A test may write *.prom files to $GWEB_TEST_OUT;
# each is checked by promcheck.py.
cd "$(dirname "$0")/../.." || exit 1
CC=${CC:-cc}
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0
while read -r name srcs; do
    case $name in ''|\#*) continue ;; esac
    if [ ! -f "test/c/$name.c" ]; then echo "FAIL $name: no test/c/$name.c"; fail=1; continue; fi
    # shellcheck disable=SC2086
    if ! $CC -std=c11 -Wall -Wextra -Werror -pthread -I test/c -I src -o "$tmp/$name" "test/c/$name.c" $srcs; then
        echo "FAIL $name: compile"; fail=1; continue
    fi
    mkdir -p "$tmp/$name.out"
    if GWEB_TEST_OUT="$tmp/$name.out" "$tmp/$name"; then :; else echo "FAIL $name"; fail=1; continue; fi
    for f in "$tmp/$name.out"/*.prom; do
        [ -f "$f" ] || continue
        python3 test/c/promcheck.py "$f" || { echo "FAIL $name: promcheck $(basename "$f")"; fail=1; }
    done
done < test/c/tests.conf
[ "$fail" = 0 ] && echo "all C tests passed"
exit $fail
