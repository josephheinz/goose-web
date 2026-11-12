/* Test stand-in for the Goose runtime header: just the builder pieces the C sources use. */
#ifndef GOOSE_STUB_H
#define GOOSE_STUB_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct { char *data; int64_t len, cap; } gs_buf;
typedef gs_buf *gs_rref;
#define GS_RREF_VALID(r) ((r) != NULL)   /* the real gs_rref is a struct: jobs.c falls back to r.hdr */

static inline void gs_bld_append(gs_rref b, const void *p, int64_t n) {
    if (n <= 0) return;
    if (b->len + n + 1 > b->cap) {
        int64_t cap = b->cap ? b->cap : 256;
        while (cap < b->len + n + 1) cap *= 2;
        b->data = realloc(b->data, (size_t)cap);
        b->cap = cap;
    }
    memcpy(b->data + b->len, p, (size_t)n);
    b->len += n;
    b->data[b->len] = 0;
}

#endif
