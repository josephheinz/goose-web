/* gzip for gweb's build-time static variants. No goose.h, so gzip_test.c can
   link it with only zlib. */
#include "gzip_core.h"

#include <stdlib.h>
#include <string.h>
#include <zlib.h>

/* The header carries no file name and an mtime of 0, so the same input always
   gives the same bytes and builds are reproducible. */
int gweb_gzip_core(const uint8_t *in, size_t n, uint8_t **out, size_t *outlen) {
    z_stream z;
    memset(&z, 0, sizeof z);
    if (deflateInit2(&z, 9, Z_DEFLATED, 31, 9, Z_DEFAULT_STRATEGY) != Z_OK) return 0;
    uLong cap = deflateBound(&z, (uLong)n) + 32;
    uint8_t *buf = malloc(cap);
    if (!buf) { deflateEnd(&z); return 0; }
    z.next_in = (Bytef *)in;
    z.avail_in = (uInt)n;
    z.next_out = buf;
    z.avail_out = (uInt)cap;
    int rc = deflate(&z, Z_FINISH);
    size_t got = z.total_out;
    deflateEnd(&z);
    if (rc != Z_STREAM_END) { free(buf); return 0; }
    *out = buf;
    *outlen = got;
    return 1;
}
