/* cc -std=c11 -Wall -Wextra src/cache_core.c test/cache_test.c -o /tmp/cache_test && /tmp/cache_test */
#include "../src/cache_core.h"

#include <stdio.h>
#include <string.h>

static int failures, checks;
#define CHECK(c, msg) do { checks++; if (!(c)) { failures++; printf("FAIL %s\n", msg); } } while (0)

static int64_t clock_ms;
static int64_t fake_now(void) { return clock_ms; }

#define S(x) (const uint8_t *)(x), strlen(x)

static int has(gc_cache *c, const char *key, const char *want) {
    const uint8_t *v;
    size_t n;
    if (!gc_get(c, S(key), &v, &n)) return 0;
    return want == NULL || (n == strlen(want) && memcmp(v, want, n) == 0);
}

static int put(gc_cache *c, const char *key, const char *val, int64_t ttl) {
    return gc_put(c, S(key), S(val), ttl);
}

int main(void) {
    gc_cache c;
    clock_ms = 1000;
    CHECK(gc_init(&c, 0, 0, fake_now), "init");
    CHECK(c.max_entries == 512 && c.max_bytes == 16 * 1024 * 1024, "default limits");

    CHECK(!has(&c, "/a", NULL), "miss on an empty cache");
    CHECK(put(&c, "/a", "one", 2000), "put");
    CHECK(has(&c, "/a", "one"), "get returns the value");
    CHECK(put(&c, "/a", "two", 2000) && has(&c, "/a", "two") && c.count == 1, "put replaces the same key");
    CHECK(put(&c, "/empty", "", 2000) && has(&c, "/empty", ""), "an empty value");

    clock_ms += 1999;
    CHECK(has(&c, "/a", "two"), "alive just before the deadline");
    clock_ms += 1;
    CHECK(!has(&c, "/a", NULL), "expired at the deadline");
    CHECK(c.count == 1, "an expired entry is dropped on get");
    CHECK(!put(&c, "/z", "x", 0) && !put(&c, "/z", "x", -5), "a ttl of 0 or less is refused");

    uint8_t big[GC_MAX_KEY + 1];
    memset(big, 'k', sizeof big);
    CHECK(gc_put(&c, big, GC_MAX_KEY, S("v"), 1000), "a key of GC_MAX_KEY bytes");
    CHECK(!gc_put(&c, big, GC_MAX_KEY + 1, S("v"), 1000), "a key over GC_MAX_KEY bytes is refused");
    gc_free(&c);

    /* Eviction: the entry that expires soonest goes, not the oldest. */
    CHECK(gc_init(&c, 3, 0, fake_now), "init with 3 entries");
    clock_ms = 0;
    put(&c, "/late", "1", 9000);
    put(&c, "/soon", "2", 1000);
    put(&c, "/mid", "3", 5000);
    CHECK(put(&c, "/new", "4", 3000), "put when full");
    CHECK(c.count == 3 && !has(&c, "/soon", NULL), "the soonest to expire was evicted");
    CHECK(has(&c, "/late", "1") && has(&c, "/mid", "3") && has(&c, "/new", "4"), "the others stay");
    clock_ms = 3000;
    CHECK(put(&c, "/after", "5", 100), "put drops expired entries before evicting");
    CHECK(has(&c, "/late", "1") && has(&c, "/mid", "3") && has(&c, "/after", "5") && c.count == 3, "no live entry was evicted");
    gc_free(&c);

    /* The byte cap counts keys and values. */
    CHECK(gc_init(&c, 0, 100, fake_now), "init with 100 bytes");
    clock_ms = 0;
    char v40[41];
    memset(v40, 'v', 40);
    v40[40] = 0;
    CHECK(put(&c, "k1", v40, 1000) && put(&c, "k2", v40, 2000), "two entries of 42 bytes");
    CHECK(c.bytes == 84, "bytes are counted");
    CHECK(put(&c, "k3", v40, 3000), "a third makes room");
    CHECK(!has(&c, "k1", NULL) && has(&c, "k2", NULL) && has(&c, "k3", NULL) && c.bytes == 84, "k1 expired soonest and went");
    char v100[101];
    memset(v100, 'v', 100);
    v100[100] = 0;
    CHECK(!put(&c, "k4", v100, 1000), "an entry over the cap is refused");
    CHECK(has(&c, "k2", NULL) && has(&c, "k3", NULL), "a refused put evicts nothing");
    CHECK(put(&c, "k2", "tiny", 5000) && c.bytes == 42 + 2 + 4, "replacing counts the new size only");
    gc_free(&c);

    /* The default limit of 512 entries. */
    CHECK(gc_init(&c, 0, 0, fake_now), "init with defaults");
    clock_ms = 0;
    char key[16];
    for (int i = 0; i < 600; i++) {
        snprintf(key, sizeof key, "/p%d", i);
        put(&c, key, "v", 1000 + i);
    }
    CHECK(c.count == 512, "512 entries at most");
    CHECK(!has(&c, "/p0", NULL) && has(&c, "/p599", NULL), "the earliest deadlines were evicted");
    gc_free(&c);

    /* The epoch: a bump empties every cache the next time it is used (D7). */
    CHECK(gc_init(&c, 0, 0, fake_now), "init for the epoch");
    clock_ms = 0;
    gc_cache d;
    CHECK(gc_init(&d, 0, 0, fake_now), "a second cache");
    put(&c, "/e1", "a", 100000);
    gc_put(&d, S("/e2"), S("b"), 100000);
    gc_sync(&c);
    gc_sync(&d);
    CHECK(has(&c, "/e1", "a") && has(&d, "/e2", "b"), "no bump: entries stay");
    int64_t e0 = gc_epoch();
    gc_epoch_bump();
    CHECK(gc_epoch() == e0 + 1, "the epoch counts up");
    gc_sync(&c);
    CHECK(c.count == 0 && !has(&c, "/e1", NULL), "after a bump the cache is empty");
    CHECK(d.count == 1, "another cache is cleared only when it is used");
    gc_sync(&d);
    CHECK(d.count == 0, "the second cache clears on its sync");
    put(&c, "/e3", "c", 100000);
    gc_sync(&c);
    CHECK(has(&c, "/e3", "c"), "an entry stored after the bump survives a sync");
    gc_clear(&c);
    CHECK(c.count == 0 && c.bytes == 0, "gc_clear empties the cache");
    gc_free(&c);
    gc_free(&d);

    /* The thread-local cache keeps its entries. */
    gc_cache *l = gc_local();
    CHECK(l != NULL && l == gc_local(), "gc_local is stable");
    CHECK(gc_put(l, S("/t"), S("v"), 60000) && has(l, "/t", "v"), "the local cache stores");

    printf("%d of %d checks passed\n", checks - failures, checks);
    return failures != 0;
}
