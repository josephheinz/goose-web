/* gweb_setenv in src/sys.c.
   Run: cc -O2 -Wall -o "$TMPDIR/et" test/env_test.c src/sys.c && "$TMPDIR/et" */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { const uint8_t *data; int64_t len; } gweb_bytes;
int32_t gweb_setenv(gweb_bytes name, gweb_bytes value);

static int checks = 0, failures = 0;

static void check(int ok, const char *what) {
    checks++;
    if (!ok) { failures++; printf("FAIL %s\n", what); }
}

static int set(const char *n, int64_t nl, const char *v, int64_t vl) {
    gweb_bytes a = { (const uint8_t *)n, nl }, b = { (const uint8_t *)v, vl };
    return gweb_setenv(a, b);
}
#define SET(n, v) set(n, (int64_t)strlen(n), v, (int64_t)strlen(v))

int main(void) {
    unsetenv("GW_T1");
    check(SET("GW_T1", "one") == 1, "sets");
    check(getenv("GW_T1") && strcmp(getenv("GW_T1"), "one") == 0, "value stored");
    check(SET("GW_T1", "two") == 1, "already set is success");
    check(strcmp(getenv("GW_T1"), "one") == 0, "not overwritten");
    unsetenv("GW_T2");
    check(SET("GW_T2", "") == 1, "empty value");
    check(getenv("GW_T2") && getenv("GW_T2")[0] == 0, "empty value stored");
    check(SET("", "x") == 0, "empty name refused");
    check(SET("A=B", "x") == 0, "= in name refused");
    check(getenv("A") == NULL, "no partial name set");
    check(set("A\0B", 3, "x", 1) == 0, "NUL in name refused");
    check(set("GW_T3", 5, "a\0b", 3) == 0, "NUL in value refused");
    check(getenv("GW_T3") == NULL, "refused value not set");
    printf("%d of %d\n", checks - failures, checks);
    return failures != 0;
}
