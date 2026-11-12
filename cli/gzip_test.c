/* cc -std=c11 -Wall -Wextra cli/gzip_test.c cli/gzip_core.c -lz -o gz && ./gz */
#include "gzip_core.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static int failures, checks;
#define CHECK(c, msg) do { checks++; if (!(c)) { failures++; printf("FAIL %s\n", msg); } } while (0)

static int inflate_gz(const uint8_t *in, size_t n, uint8_t *out, size_t cap, size_t *got) {
    z_stream z;
    memset(&z, 0, sizeof z);
    if (inflateInit2(&z, 31) != Z_OK) return 0;
    z.next_in = (Bytef *)in;
    z.avail_in = (uInt)n;
    z.next_out = out;
    z.avail_out = (uInt)cap;
    int rc = inflate(&z, Z_FINISH);
    *got = z.total_out;
    inflateEnd(&z);
    return rc == Z_STREAM_END;
}

static void round_trip(const char *name, const uint8_t *src, size_t n) {
    uint8_t *a, *b;
    size_t alen, blen;
    CHECK(gweb_gzip_core(src, n, &a, &alen), name);
    CHECK(gweb_gzip_core(src, n, &b, &blen), name);
    if (failures) return;
    CHECK(alen == blen && memcmp(a, b, alen) == 0, "two runs differ");
    CHECK(alen >= 10 && a[0] == 0x1f && a[1] == 0x8b && a[2] == 8, "gzip magic and method");
    CHECK(a[3] == 0, "no name, comment or extra flags");
    CHECK(a[4] == 0 && a[5] == 0 && a[6] == 0 && a[7] == 0, "mtime is 0");
    uint8_t *back = malloc(n + 1);
    size_t got = 0;
    CHECK(inflate_gz(a, alen, back, n + 1, &got), "inflate");
    CHECK(got == n && memcmp(back, src, n) == 0, "round trip");
    free(back); free(a); free(b);
}

int main(void) {
    char text[4000];
    size_t n = 0;
    while (n < sizeof text - 40) n += (size_t)snprintf(text + n, sizeof text - n, ".rule-%zu { color: red; }\n", n % 17);
    round_trip("repetitive text", (const uint8_t *)text, n);
    round_trip("empty input", (const uint8_t *)"", 0);

    uint8_t noise[2048];
    unsigned s = 12345;
    for (size_t i = 0; i < sizeof noise; i++) { s = s * 1103515245u + 12345u; noise[i] = (uint8_t)(s >> 16); }
    round_trip("incompressible bytes", noise, sizeof noise);

    uint8_t *z;
    size_t zlen;
    CHECK(gweb_gzip_core((const uint8_t *)text, n, &z, &zlen) && zlen * 10 <= n * 9, "repetitive text shrinks below 90%");
    free(z);

    printf("%d of %d checks passed\n", checks - failures, checks);
    return failures != 0;
}
