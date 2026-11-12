/* Process-wide GCRA rate limiter (DESIGN-ADDENDUM-13, D6). Portable C, libc only. */
#include <pthread.h>
#include <stdint.h>
#include <time.h>

typedef struct { const uint8_t *data; int64_t len; } gweb_bytes;

#define SLOTS 8192
#define PROBES 8

typedef struct { uint64_t key; int64_t tat_ms; } slot;

static slot table[SLOTS];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static uint64_t fnv1a(gweb_bytes b) {
    uint64_t h = 14695981039346656037ULL;
    for (int64_t i = 0; i < b.len; i++) { h ^= b.data[i]; h *= 1099511628211ULL; }
    return h ? h : 1;   /* 0 marks an empty slot */
}

/* Milliseconds on the monotonic clock; wall-clock jumps must not reset limits. */
int64_t gweb_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* 0 = allowed, else the milliseconds to wait (at least 1). */
int64_t gweb_rate_take(gweb_bytes key, int64_t now_ms, int64_t period_ms, int64_t limit) {
    if (limit < 1 || period_ms < 1) return period_ms < 1 ? 1 : period_ms;
    int64_t t = period_ms / limit;
    if (t < 1) t = 1;
    uint64_t k = fnv1a(key);
    pthread_mutex_lock(&lock);
    slot *s = NULL, *free_slot = NULL, *oldest = NULL;
    for (int i = 0; i < PROBES; i++) {
        slot *c = &table[(k + (uint64_t)i) % SLOTS];
        if (c->key == k) { s = c; break; }
        if (!free_slot && (c->key == 0 || c->tat_ms <= now_ms)) free_slot = c;
        if (!oldest || c->tat_ms < oldest->tat_ms) oldest = c;
    }
    if (!s) { s = free_slot ? free_slot : oldest; s->key = k; s->tat_ms = 0; }
    int64_t tat = s->tat_ms > now_ms ? s->tat_ms : now_ms;
    int64_t new_tat = tat + t;
    int64_t wait = 0;
    if (new_tat - now_ms > period_ms) {
        wait = new_tat - now_ms - period_ms;
        if (wait < 1) wait = 1;
    } else {
        s->tat_ms = new_tat;
    }
    pthread_mutex_unlock(&lock);
    return wait;
}

/* Tests only. */
void gweb_rate_reset(void) {
    pthread_mutex_lock(&lock);
    for (int i = 0; i < SLOTS; i++) { table[i].key = 0; table[i].tat_ms = 0; }
    pthread_mutex_unlock(&lock);
}
