/* The goose side of the page cache: the calling worker thread's cache, over cache_core. */
#include "goose.h"
#include "cache_core.h"

#include <stdint.h>

typedef struct { const uint8_t *data; int64_t len; } gweb_bytes;

/* Appends the value to out and returns 1; 0 on a miss. */
int32_t gweb_cache_get(gweb_bytes key, gs_rref out) {
    gc_cache *c = gc_local();
    const uint8_t *v;
    size_t n;
    if (c) gc_sync(c);
    if (!c || key.len < 0 || !gc_get(c, key.data, (size_t)key.len, &v, &n)) return 0;
    gs_bld_append(out, v, n);
    return 1;
}

int32_t gweb_cache_put(gweb_bytes key, gweb_bytes val, int64_t ttl_ms) {
    gc_cache *c = gc_local();
    if (c) gc_sync(c);
    if (!c || key.len < 0 || val.len < 0) return 0;
    return gc_put(c, key.data, (size_t)key.len, val.data, (size_t)val.len, ttl_ms);
}

void gweb_epoch_bump(void) { gc_epoch_bump(); }
int64_t gweb_epoch(void) { return gc_epoch(); }
