#ifndef GWEB_CACHE_CORE_H
#define GWEB_CACHE_CORE_H
#include <stddef.h>
#include <stdint.h>

#define GC_MAX_ENTRIES 512
#define GC_MAX_BYTES (16 * 1024 * 1024)
#define GC_MAX_KEY 1280

typedef struct gc_entry {
    uint8_t *key;
    size_t klen;
    uint8_t *val;
    size_t vlen;
    int64_t expires;    /* milliseconds on the cache's clock */
} gc_entry;

typedef struct gc_cache {
    gc_entry *entries;  /* unordered; capacity max_entries */
    size_t count;
    size_t bytes;       /* sum of key and value lengths */
    size_t max_entries;
    size_t max_bytes;
    int64_t (*now)(void);
    int64_t epoch;      /* the process epoch this cache last saw */
} gc_cache;

/* Zero limits mean the defaults; a NULL clock means a monotonic one. Returns 0 when out of memory. */
int gc_init(gc_cache *c, size_t max_entries, size_t max_bytes, int64_t (*now)(void));
void gc_free(gc_cache *c);

/* Stores a copy for ttl_ms, replacing any entry with the key. When full it drops expired entries,
   then evicts whichever expires soonest until the new one fits. Returns 0, storing nothing and
   leaving the cache as it was, for a key over GC_MAX_KEY, ttl_ms <= 0, an entry larger than the byte cap,
   or out of memory. */
int gc_put(gc_cache *c, const uint8_t *key, size_t klen, const uint8_t *val, size_t vlen, int64_t ttl_ms);

/* 1 with *val and *vlen pointing into the cache (valid until the next put or get), 0 on a miss or an expired entry. */
int gc_get(gc_cache *c, const uint8_t *key, size_t klen, const uint8_t **val, size_t *vlen);

/* Drops every entry. */
void gc_clear(gc_cache *c);

/* The process-wide epoch (DESIGN-ADDENDUM-19, D7). gc_epoch_bump runs on any thread after a content change;
   gc_sync, called before a get or put, clears a cache that last saw an older epoch. */
void gc_epoch_bump(void);
int64_t gc_epoch(void);
void gc_sync(gc_cache *c);

/* The calling thread's cache, made on first use; NULL when out of memory. */
gc_cache *gc_local(void);
#endif
