/* A per-thread response cache: no locks, bounded by entry count and bytes. */
#include "cache_core.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int64_t mono_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

int gc_init(gc_cache *c, size_t max_entries, size_t max_bytes, int64_t (*now)(void)) {
    memset(c, 0, sizeof *c);
    c->max_entries = max_entries ? max_entries : GC_MAX_ENTRIES;
    c->max_bytes = max_bytes ? max_bytes : GC_MAX_BYTES;
    c->now = now ? now : mono_ms;
    c->epoch = gc_epoch();
    c->entries = calloc(c->max_entries, sizeof(gc_entry));
    return c->entries != NULL;
}

static void drop(gc_cache *c, size_t i) {
    gc_entry *e = &c->entries[i];
    c->bytes -= e->klen + e->vlen;
    free(e->key);
    free(e->val);
    *e = c->entries[--c->count];
}

void gc_free(gc_cache *c) {
    while (c->count > 0) drop(c, c->count - 1);
    free(c->entries);
    c->entries = NULL;
}

static long find(gc_cache *c, const uint8_t *key, size_t klen) {
    for (size_t i = 0; i < c->count; i++)
        if (c->entries[i].klen == klen && memcmp(c->entries[i].key, key, klen) == 0) return (long)i;
    return -1;
}

static _Atomic int64_t process_epoch;

void gc_clear(gc_cache *c) { while (c->count > 0) drop(c, c->count - 1); }
void gc_epoch_bump(void) { atomic_fetch_add_explicit(&process_epoch, 1, memory_order_release); }
int64_t gc_epoch(void) { return atomic_load_explicit(&process_epoch, memory_order_acquire); }
void gc_sync(gc_cache *c) {
    int64_t e = gc_epoch();
    if (c->epoch != e) { gc_clear(c); c->epoch = e; }
}

int gc_put(gc_cache *c, const uint8_t *key, size_t klen, const uint8_t *val, size_t vlen, int64_t ttl_ms) {
    if (klen > GC_MAX_KEY || ttl_ms <= 0 || klen + vlen > c->max_bytes) return 0;
    /* Copy first, so a failed allocation leaves the old entry in place. */
    uint8_t *k = malloc(klen ? klen : 1), *v = malloc(vlen ? vlen : 1);
    if (!k || !v) { free(k); free(v); return 0; }
    memcpy(k, key, klen);
    if (vlen) memcpy(v, val, vlen);

    long at = find(c, key, klen);
    if (at >= 0) drop(c, (size_t)at);
    int64_t now = c->now();
    for (size_t i = 0; i < c->count;) {
        if (c->entries[i].expires <= now) drop(c, i); else i++;
    }
    while (c->count >= c->max_entries || c->bytes + klen + vlen > c->max_bytes) {
        size_t soonest = 0;
        for (size_t i = 1; i < c->count; i++)
            if (c->entries[i].expires < c->entries[soonest].expires) soonest = i;
        drop(c, soonest);
    }
    c->entries[c->count++] = (gc_entry){ k, klen, v, vlen, now + ttl_ms };
    c->bytes += klen + vlen;
    return 1;
}

int gc_get(gc_cache *c, const uint8_t *key, size_t klen, const uint8_t **val, size_t *vlen) {
    long at = find(c, key, klen);
    if (at < 0) return 0;
    gc_entry *e = &c->entries[at];
    if (e->expires <= c->now()) { drop(c, (size_t)at); return 0; }
    *val = e->val;
    *vlen = e->vlen;
    return 1;
}

static _Thread_local gc_cache local;
static _Thread_local int local_ready;

gc_cache *gc_local(void) {
    if (!local_ready) {
        if (!gc_init(&local, 0, 0, NULL)) return NULL;
        local_ready = 1;
    }
    return &local;
}
