/* gweb's gzip extern: glue between Goose slices and gzip_core.c. */
#include "goose.h"

#include <stdint.h>
#include <stdlib.h>

#include "gzip_core.h"

typedef struct { const uint8_t *data; int64_t len; } gweb_bytes;

/* Appends the gzip of in to out and returns 1, or returns 0 and leaves out alone. */
int32_t gweb_gzip(gweb_bytes in, gs_rref out) {
    uint8_t *z;
    size_t n;
    if (!gweb_gzip_core(in.data, (size_t)in.len, &z, &n)) return 0;
    gs_bld_append(out, z, n);
    free(z);
    return 1;
}
