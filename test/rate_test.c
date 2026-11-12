/* GCRA limiter checks for src/rate.c.
   Run: cc -O2 -Wall -o "$TMPDIR/rt" test/rate_test.c src/rate.c -lpthread && "$TMPDIR/rt" */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct { const uint8_t *data; int64_t len; } gweb_bytes;
int64_t gweb_rate_take(gweb_bytes key, int64_t now_ms, int64_t period_ms, int64_t limit);
void gweb_rate_reset(void);
int64_t gweb_now_ms(void);

static int checks = 0, failures = 0;

static void check(int ok, const char *what) {
    checks++;
    if (!ok) { failures++; printf("FAIL %s\n", what); }
}

static int64_t take(const char *key, int64_t now, int64_t period, int64_t limit) {
    gweb_bytes k = { (const uint8_t *)key, (int64_t)strlen(key) };
    return gweb_rate_take(k, now, period, limit);
}

static void basic(void) {
    gweb_rate_reset();
    check(take("a", 0, 1000, 3) == 0, "1st allowed");
    check(take("a", 0, 1000, 3) == 0, "2nd allowed");
    check(take("a", 0, 1000, 3) == 0, "3rd allowed");
    /* T = 333; tat = 999 after 3 takes, a 4th gives 1332 - 1000 = 332 */
    check(take("a", 0, 1000, 3) == 332, "4th refused with the wait");
    check(take("a", 0, 1000, 3) == 332, "a refusal does not advance the clock");
    check(take("a", 331, 1000, 3) == 1, "still refused 1 ms early");
    check(take("a", 332, 1000, 3) == 0, "allowed again after the wait");
    check(take("a", 332, 1000, 3) > 0, "and then refused once more");
    check(take("b", 0, 1000, 3) == 0, "distinct key independent");
    check(take("a", 100000, 1000, 3) == 0, "idle key recovers fully");
}

static void bad_args(void) {
    gweb_rate_reset();
    check(take("x", 0, 1000, 0) == 1000, "limit 0 refuses with period");
    check(take("x", 0, 0, 5) >= 1, "period 0 refuses");
    check(take("x", 0, 1000, 5000) == 0, "limit above period still allows (T=1)");
}

/* 8 linear probes from one slot: key hashes are not controllable, so fill the whole table. */
static void eviction(void) {
    gweb_rate_reset();
    char key[32];
    for (int i = 0; i < 20000; i++) {
        snprintf(key, sizeof key, "k%d", i);
        take(key, 0, 1000000, 1);
    }
    /* every key took its only token at now=0 and is live; new keys must still be admitted by eviction */
    int ok = 1;
    for (int i = 0; i < 100; i++) {
        snprintf(key, sizeof key, "new%d", i);
        if (take(key, 1, 1000000, 1) != 0) ok = 0;
    }
    check(ok, "fresh keys admitted when every probe slot is live");
    /* a just-admitted key keeps its state */
    check(take("new99", 2, 1000000, 1) > 0, "the newest key is not lost");
}

static void expiry(void) {
    gweb_rate_reset();
    char key[32];
    for (int i = 0; i < 20000; i++) {
        snprintf(key, sizeof key, "e%d", i);
        take(key, 0, 10, 1);
    }
    int ok = 1;
    for (int i = 0; i < 100; i++) {
        snprintf(key, sizeof key, "f%d", i);
        if (take(key, 1000, 10, 1) != 0) ok = 0;
    }
    check(ok, "expired slots are reused");
}

#define THREADS 8
#define TRIES 1000
static int64_t allowed[THREADS];

static void *hammer(void *arg) {
    int id = (int)(intptr_t)arg;
    for (int i = 0; i < TRIES; i++)
        if (take("shared", 5000, 1000, 100) == 0) allowed[id]++;
    return NULL;
}

static void threads(void) {
    gweb_rate_reset();
    pthread_t th[THREADS];
    for (int i = 0; i < THREADS; i++) pthread_create(&th[i], NULL, hammer, (void *)(intptr_t)i);
    for (int i = 0; i < THREADS; i++) pthread_join(th[i], NULL);
    int64_t total = 0;
    for (int i = 0; i < THREADS; i++) total += allowed[i];
    check(total == 100, "8 threads on one key allow exactly the limit");
}

static void clock_ok(void) {
    int64_t a = gweb_now_ms(), b = gweb_now_ms();
    check(a > 0 && b >= a, "monotonic ms clock");
}

int main(void) {
    basic(); bad_args(); eviction(); expiry(); threads(); clock_ok();
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
