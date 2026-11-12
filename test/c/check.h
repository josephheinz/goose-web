/* Minimal checks for C tests: CHECK counts, names each failure, and done() sets the exit code. */
#ifndef CHECK_H
#define CHECK_H
#include <stdio.h>

static int checks_n, checks_bad;
#define CHECK(cond) do { checks_n++; if (!(cond)) { checks_bad++; printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)
static int done(void) {
    if (checks_bad) { printf("%d of %d checks failed\n", checks_bad, checks_n); return 1; }
    printf("ok %d checks\n", checks_n);
    return 0;
}
#endif
