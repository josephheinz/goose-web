#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "goose.h"
#include "ops.h"
#include "check.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define S(lit) ((gweb_bytes){(const uint8_t *)(lit), (int64_t)strlen(lit)})

static _Atomic int64_t fake;
static int64_t fake_now(void) { return atomic_load(&fake); }
static void set_clock(int64_t ms) { atomic_store(&fake, ms); gweb_jobs_test_kick(); }

static int64_t mono_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* takes one job; returns the payload in buf (NUL-terminated) or NULL */
static int take(int slot, int64_t timeout, char *buf, int64_t *id, int64_t *attempt, char *sname) {
    gs_buf b = {0}, n = {0};
    int64_t i = 0, a = 0;
    int r = gweb_jobs_take(slot, timeout, &b, &i, &a, &n);
    if (buf) snprintf(buf, 64, "%s", b.data ? b.data : "");
    if (sname) snprintf(sname, 64, "%s", n.data ? n.data : "");
    if (id) *id = i;
    if (attempt) *attempt = a;
    free(b.data); free(n.data);
    return r;
}

static int64_t utc(int y, int mo, int d, int h, int mi, int sec) {
    struct tm tm = {0};
    tm.tm_year = y - 1900; tm.tm_mon = mo - 1; tm.tm_mday = d; tm.tm_hour = h; tm.tm_min = mi; tm.tm_sec = sec;
    return (int64_t)timegm(&tm);
}

static void test_fifo_and_delay(void) {
    gweb_jobs_test_clock(fake_now);
    set_clock(100000);
    gweb_jobs_init(1, 100, 5);
    char buf[64];
    int64_t id, att;
    CHECK(gweb_jobs_push(S("a"), 0) && gweb_jobs_push(S("b"), 0) && gweb_jobs_push(S("c"), 0));
    CHECK(gweb_jobs_stat(0) == 3);
    for (int i = 0; i < 3; i++) {
        CHECK(take(0, 0, buf, &id, &att, NULL) == 1);
        CHECK(buf[0] == 'a' + i && id == i + 1 && att == 1);
        CHECK(gweb_jobs_stat(1) == 1);
        gweb_jobs_done(0, 1);
    }
    CHECK(take(0, 0, buf, NULL, NULL, NULL) == 0);
    CHECK(gweb_jobs_stat(2) == 3 && gweb_jobs_stat(1) == 0 && gweb_jobs_stat(0) == 0);

    /* delay is respected; ready jobs go in insertion order */
    gweb_jobs_init(1, 100, 5);
    CHECK(gweb_jobs_push(S("late"), 5000));
    CHECK(gweb_jobs_push(S("now"), 0));
    CHECK(take(0, 0, buf, NULL, NULL, NULL) == 1 && strcmp(buf, "now") == 0);
    gweb_jobs_done(0, 1);
    set_clock(104999);
    CHECK(take(0, 0, buf, NULL, NULL, NULL) == 0);
    set_clock(105000);
    CHECK(take(0, 0, buf, NULL, NULL, NULL) == 1 && strcmp(buf, "late") == 0);
    gweb_jobs_done(0, 1);

    gweb_jobs_init(1, 100, 5);
    gweb_jobs_push(S("first"), 1000);
    gweb_jobs_push(S("second"), 0);
    gweb_jobs_push(S("third"), 0);
    set_clock(106000);
    CHECK(take(0, 0, buf, NULL, NULL, NULL) == 1 && strcmp(buf, "first") == 0);
    gweb_jobs_done(0, 1);
    CHECK(take(0, 0, buf, NULL, NULL, NULL) == 1 && strcmp(buf, "second") == 0);
    gweb_jobs_done(0, 1);

    /* binary and empty payloads */
    gweb_jobs_init(1, 100, 5);
    CHECK(gweb_jobs_push((gweb_bytes){(const uint8_t *)"\0\1\2", 3}, 0));
    CHECK(gweb_jobs_push((gweb_bytes){NULL, 0}, 0));
    gs_buf b = {0};
    CHECK(gweb_jobs_take(0, 0, &b, NULL, NULL, NULL) == 1 && b.len == 3 && memcmp(b.data, "\0\1\2", 3) == 0);
    gweb_jobs_done(0, 1);
    free(b.data);
    gs_buf e = {0};
    CHECK(gweb_jobs_take(0, 0, &e, NULL, NULL, NULL) == 1 && e.len == 0);
    gweb_jobs_done(0, 1);
    CHECK(gweb_jobs_push(S("x"), -1) == 0);
    gweb_jobs_test_clock(NULL);
}

static void test_capacity(void) {
    gweb_jobs_test_clock(fake_now);
    set_clock(1000);
    gweb_jobs_init(1, 2, 5);
    char buf[64];
    CHECK(gweb_jobs_push(S("a"), 0));
    CHECK(gweb_jobs_push(S("b"), 60000));
    CHECK(gweb_jobs_push(S("c"), 0) == 0);
    CHECK(gweb_jobs_stat(5) == 1 && gweb_jobs_stat(0) == 2);
    CHECK(take(0, 0, buf, NULL, NULL, NULL) == 1); /* running jobs do not count */
    CHECK(gweb_jobs_push(S("c"), 0));
    CHECK(gweb_jobs_push(S("d"), 0) == 0);
    CHECK(gweb_jobs_stat(5) == 2 && gweb_jobs_stat(0) == 2 && gweb_jobs_stat(1) == 1);
    gweb_jobs_done(0, 1);
    gweb_jobs_test_clock(NULL);
}

static void test_retry(void) {
    gweb_jobs_test_clock(fake_now);
    set_clock(100000);
    gweb_jobs_init(1, 10, 3);
    char buf[64];
    int64_t id, att;
    gweb_jobs_push(S("r"), 0);
    CHECK(take(0, 0, buf, &id, &att, NULL) == 1 && att == 1);
    gweb_jobs_done(0, 0);
    CHECK(gweb_jobs_stat(3) == 1 && gweb_jobs_stat(0) == 1 && gweb_jobs_stat(1) == 0);
    set_clock(100999);
    CHECK(take(0, 0, buf, NULL, NULL, NULL) == 0);
    set_clock(101000);
    CHECK(take(0, 0, buf, &id, &att, NULL) == 1 && att == 2 && id == 1 && strcmp(buf, "r") == 0);
    gweb_jobs_done(0, 0);
    set_clock(102999);
    CHECK(take(0, 0, buf, NULL, NULL, NULL) == 0);
    set_clock(103000);
    CHECK(take(0, 0, buf, &id, &att, NULL) == 1 && att == 3);
    gweb_jobs_done(0, 0);
    CHECK(gweb_jobs_stat(4) == 1 && gweb_jobs_stat(0) == 0 && gweb_jobs_stat(3) == 3 && gweb_jobs_stat(2) == 0);
    set_clock(900000);
    CHECK(take(0, 0, buf, NULL, NULL, NULL) == 0);

    /* success on a retry */
    gweb_jobs_init(1, 10, 5);
    gweb_jobs_push(S("s"), 0);
    set_clock(1000000);
    take(0, 0, buf, NULL, NULL, NULL);
    gweb_jobs_done(0, 0);
    set_clock(1001000);
    CHECK(take(0, 0, buf, &id, &att, NULL) == 1 && att == 2);
    gweb_jobs_done(0, 1);
    CHECK(gweb_jobs_stat(2) == 1 && gweb_jobs_stat(3) == 1 && gweb_jobs_stat(4) == 0);

    /* the delay doubles and is capped at 5 minutes */
    gweb_jobs_init(1, 10, 20);
    set_clock(2000000);
    gweb_jobs_push(S("cap"), 0);
    int64_t t = 2000000;
    for (int k = 1; k <= 12; k++) {
        CHECK(take(0, 0, buf, &id, &att, NULL) == 1 && att == k);
        gweb_jobs_done(0, 0);
        int64_t d = 1000;
        for (int i = 1; i < k; i++) d *= 2;
        if (d > 300000) d = 300000;
        set_clock(t + d - 1);
        CHECK(take(0, 0, buf, NULL, NULL, NULL) == 0);
        t += d;
        set_clock(t);
    }
    CHECK(gweb_jobs_stat(3) == 12);

    /* abandon counts as a failed attempt and requeues; with no current job it returns 0 */
    gweb_jobs_init(1, 10, 5);
    set_clock(5000000);
    CHECK(gweb_jobs_abandon(0) == 0);
    gweb_jobs_push(S("ab"), 0);
    take(0, 0, buf, NULL, NULL, NULL);
    CHECK(gweb_jobs_abandon(0) == 1);
    CHECK(gweb_jobs_stat(3) == 1 && gweb_jobs_stat(1) == 0 && gweb_jobs_stat(0) == 1);
    CHECK(gweb_jobs_abandon(0) == 0);
    gweb_jobs_done(0, 1);
    CHECK(gweb_jobs_stat(2) == 0);
    set_clock(5001000);
    CHECK(take(0, 0, buf, &id, &att, NULL) == 1 && att == 2);
    gweb_jobs_done(0, 1);
    CHECK(gweb_jobs_stat(2) == 1);

    /* a take on a slot that still holds a job fails that job */
    gweb_jobs_init(1, 10, 5);
    gweb_jobs_push(S("one"), 0);
    take(0, 0, buf, NULL, NULL, NULL);
    CHECK(take(0, 0, buf, NULL, NULL, NULL) == 0 && gweb_jobs_stat(3) == 1 && gweb_jobs_stat(0) == 1);
    gweb_jobs_test_clock(NULL);
}

static void test_every(void) {
    gweb_jobs_test_clock(fake_now);
    set_clock(1000000);
    gweb_jobs_init(2, 10, 5);
    char buf[64], name[64];
    int64_t id, att;
    CHECK(gweb_jobs_every(S("tick"), 1000, S("T")));
    CHECK(gweb_jobs_every(S("tick"), 1000, S("T")) == 0); /* duplicate */
    CHECK(gweb_jobs_every(S(""), 1000, S("T")) == 0);
    CHECK(gweb_jobs_every(S("0123456789012345678901234567890123"), 1000, S("T")) == 0); /* 34 bytes */
    CHECK(gweb_jobs_every(S("012345678901234567890123456789ab"), 500000, S("L")) == 1);   /* 32 bytes */
    CHECK(gweb_jobs_every(S("zero"), 0, S("T")) == 0);
    set_clock(1000999);
    CHECK(take(0, 0, buf, NULL, NULL, name) == 0);
    set_clock(1001000);
    CHECK(take(0, 0, buf, &id, &att, name) == 1 && strcmp(buf, "T") == 0 && strcmp(name, "tick") == 0 && att == 1);
    CHECK(take(1, 0, buf, NULL, NULL, name) == 0);
    /* still running: the next tick is skipped */
    set_clock(1002000);
    CHECK(take(1, 0, buf, NULL, NULL, name) == 0);
    CHECK(gweb_jobs_stat(0) == 0 && gweb_jobs_stat(1) == 1);
    gweb_jobs_done(0, 1);
    set_clock(1003000);
    CHECK(take(0, 0, buf, NULL, NULL, name) == 1 && strcmp(name, "tick") == 0);
    gweb_jobs_done(0, 1);
    /* ad-hoc jobs carry no schedule name */
    gweb_jobs_push(S("adhoc"), 0);
    CHECK(take(0, 0, buf, NULL, NULL, name) == 1 && strcmp(buf, "adhoc") == 0 && name[0] == 0);
    gweb_jobs_done(0, 1);
    /* a failed scheduled job keeps its schedule blocked through the retry */
    set_clock(1004000);
    CHECK(take(0, 0, buf, NULL, NULL, name) == 1 && strcmp(name, "tick") == 0);
    gweb_jobs_done(0, 0);
    set_clock(1005000);
    CHECK(take(0, 0, buf, &id, &att, name) == 1 && att == 2 && strcmp(name, "tick") == 0);
    CHECK(take(1, 0, buf, NULL, NULL, name) == 0 && gweb_jobs_stat(0) == 0);
    gweb_jobs_done(0, 1);
    /* the 32-byte name comes back whole */
    set_clock(1500000);
    int saw = 0;
    for (int i = 0; i < 2; i++)
        if (take(i, 0, buf, NULL, NULL, name) == 1 && strcmp(name, "012345678901234567890123456789ab") == 0 && strcmp(buf, "L") == 0) saw = 1;
    CHECK(saw);
    gweb_jobs_test_clock(NULL);
}

static void test_cron_schedule(void) {
    setenv("TZ", "UTC", 1);
    tzset();
    gweb_jobs_test_clock(fake_now);
    set_clock(utc(2025, 1, 15, 10, 7, 30) * 1000);
    gweb_jobs_init(1, 10, 5);
    CHECK(gweb_jobs_cron(S("q"), S("*/15 * * * *"), S("C")));
    CHECK(gweb_jobs_cron(S("q"), S("*/15 * * * *"), S("C")) == 0);
    CHECK(gweb_jobs_cron(S("bad"), S("60 * * * *"), S("C")) == 0);
    CHECK(gweb_jobs_cron(S("bad"), S("* * *"), S("C")) == 0);
    char buf[64], name[64];
    set_clock((utc(2025, 1, 15, 10, 15, 0) - 1) * 1000);
    CHECK(take(0, 0, buf, NULL, NULL, name) == 0);
    set_clock(utc(2025, 1, 15, 10, 15, 0) * 1000);
    CHECK(take(0, 0, buf, NULL, NULL, name) == 1 && strcmp(name, "q") == 0 && strcmp(buf, "C") == 0);
    gweb_jobs_done(0, 1);
    CHECK(take(0, 0, buf, NULL, NULL, name) == 0);
    set_clock(utc(2025, 1, 15, 10, 30, 0) * 1000);
    CHECK(take(0, 0, buf, NULL, NULL, name) == 1);
    gweb_jobs_done(0, 1);
    gweb_jobs_test_clock(NULL);
}

static void next_is(const char *spec, int64_t after, int64_t want, int line) {
    int64_t got = gweb_cron_next(S(spec), after);
    checks_n++;
    if (got != want) { checks_bad++; printf("FAIL line %d: cron_next(\"%s\") = %lld, want %lld\n", line, spec, (long long)got, (long long)want); }
}
#define NEXT(spec, after, want) next_is(spec, after, want, __LINE__)

static void test_cron_table(void) {
    setenv("TZ", "UTC", 1);
    tzset();
    int64_t ref = utc(2025, 1, 15, 10, 7, 30); /* Wed */
    NEXT("*/15 * * * *", ref, utc(2025, 1, 15, 10, 15, 0));
    NEXT("*/15 * * * *", utc(2025, 1, 15, 10, 15, 0), utc(2025, 1, 15, 10, 30, 0)); /* strictly after */
    NEXT("* * * * *", ref, utc(2025, 1, 15, 10, 8, 0));
    NEXT("0 8 * * 1", ref, utc(2025, 1, 20, 8, 0, 0));
    NEXT("0 0 1 * *", ref, utc(2025, 2, 1, 0, 0, 0));
    NEXT("30 2 * * 1-5", utc(2025, 1, 17, 3, 0, 0), utc(2025, 1, 20, 2, 30, 0));
    NEXT("30 2 * * 1-5", utc(2025, 1, 15, 3, 0, 0), utc(2025, 1, 16, 2, 30, 0));
    NEXT("0 12 1,15 * *", ref, utc(2025, 1, 15, 12, 0, 0));
    NEXT("0 12 1,15 * *", utc(2025, 1, 15, 12, 0, 0), utc(2025, 2, 1, 12, 0, 0));
    NEXT("0 0 13 * 5", utc(2025, 1, 1, 0, 0, 0), utc(2025, 1, 3, 0, 0, 0));  /* dom OR dow */
    NEXT("0 0 13 * 5", utc(2025, 1, 10, 0, 0, 0), utc(2025, 1, 13, 0, 0, 0));
    NEXT("0 0 13 * 5", utc(2025, 1, 13, 0, 0, 0), utc(2025, 1, 17, 0, 0, 0));
    NEXT("0 0 13 * *", utc(2025, 1, 1, 0, 0, 0), utc(2025, 1, 13, 0, 0, 0)); /* only dom restricted */
    NEXT("0 0 29 2 *", utc(2025, 3, 1, 0, 0, 0), utc(2028, 2, 29, 0, 0, 0));
    NEXT("0 0 29 2 *", utc(2028, 2, 29, 0, 0, 0), utc(2032, 2, 29, 0, 0, 0));
    NEXT("0 0 29 2 *", utc(2096, 3, 1, 0, 0, 0), -1); /* 2100 is not a leap year, 2104 is beyond 5 years */
    NEXT("10-20/5 * * * *", ref, utc(2025, 1, 15, 10, 10, 0));
    NEXT("10-20/5 * * * *", utc(2025, 1, 15, 10, 10, 0), utc(2025, 1, 15, 10, 15, 0));
    NEXT("10-20/5 * * * *", utc(2025, 1, 15, 10, 20, 0), utc(2025, 1, 15, 11, 10, 0));
    NEXT("0 0 * * 7", ref, utc(2025, 1, 19, 0, 0, 0));
    NEXT("0 0 * * 0", ref, utc(2025, 1, 19, 0, 0, 0));
    NEXT("0 0 * * 6-7", ref, utc(2025, 1, 18, 0, 0, 0));
    NEXT("0 0 1 1 *", ref, utc(2026, 1, 1, 0, 0, 0));
    NEXT("59 23 31 12 *", ref, utc(2025, 12, 31, 23, 59, 0));
    NEXT("0 0 31 * *", utc(2025, 4, 1, 0, 0, 0), utc(2025, 5, 31, 0, 0, 0));
    NEXT("  5   4 * * *  ", ref, utc(2025, 1, 16, 4, 5, 0));
    NEXT("0 0 1,3-5/2 6,12 *", utc(2025, 6, 1, 0, 0, 0), utc(2025, 6, 3, 0, 0, 0));
    NEXT("0 0 30 2 *", ref, -1);
    NEXT("0 0 * * *", utc(1969, 12, 31, 12, 0, 0), utc(1970, 1, 1, 0, 0, 0));

    const char *bad[] = {"60 * * * *", "* * *", "a b c d e", "* * * * * *", "*/0 * * * *", "", "1-2-3 * * * *", "5/2 * * * *",
                         "* 24 * * *", "* * 0 * *", "* * 32 * *", "* * * 0 *", "* * * 13 *", "* * * * 8", ",* * * * *", "1, * * * *",
                         "5-3 * * * *", "-1 * * * *", "* * * * *x", "*/ * * * *", "1- * * * *"};
    for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) {
        checks_n++;
        if (gweb_cron_next(S(bad[i]), ref) != -1) { checks_bad++; printf("FAIL: bad spec accepted: \"%s\"\n", bad[i]); }
    }
}

static void test_cron_dst(void) {
    setenv("TZ", "America/New_York", 1);
    tzset();
    /* spring forward 2025-03-09: 02:00 EST jumps to 03:00 EDT; local times 02:00-02:59 do not exist and are skipped */
    NEXT("30 2 * * *", utc(2025, 3, 8, 8, 0, 0), utc(2025, 3, 10, 6, 30, 0));   /* Mar 9 is skipped; Mar 10 02:30 EDT */
    NEXT("30 2 * * *", utc(2025, 3, 7, 8, 0, 0), utc(2025, 3, 8, 7, 30, 0));    /* Mar 8 02:30 EST */
    NEXT("*/30 * * * *", utc(2025, 3, 9, 6, 30, 0), utc(2025, 3, 9, 7, 0, 0));  /* 01:30 EST -> 03:00 EDT */
    NEXT("0 3 * * *", utc(2025, 3, 8, 12, 0, 0), utc(2025, 3, 9, 7, 0, 0));     /* 03:00 EDT exists */
    /* fall back 2025-11-02: 01:00-01:59 occur twice and fire once, at the first (EDT) occurrence */
    NEXT("30 1 * * *", utc(2025, 11, 2, 4, 0, 0), utc(2025, 11, 2, 5, 30, 0));  /* 01:30 EDT */
    NEXT("30 1 * * *", utc(2025, 11, 2, 5, 30, 0), utc(2025, 11, 3, 6, 30, 0)); /* not 06:30 UTC on Nov 2 (01:30 EST) */
    NEXT("30 1 * * *", utc(2025, 11, 2, 6, 0, 0), utc(2025, 11, 3, 6, 30, 0));  /* inside the repeated hour */
    NEXT("0 2 * * *", utc(2025, 11, 2, 5, 30, 0), utc(2025, 11, 2, 7, 0, 0));   /* 02:00 EST */
    NEXT("*/30 1-2 * * *", utc(2025, 11, 2, 5, 30, 0), utc(2025, 11, 2, 7, 0, 0)); /* skips the repeat, 02:00 EST */
    NEXT("0 12 * * *", utc(2025, 11, 1, 20, 0, 0), utc(2025, 11, 2, 17, 0, 0));  /* noon EST */
    /* far from any change: plain offsets */
    NEXT("0 8 * * 1", utc(2025, 7, 1, 0, 0, 0), utc(2025, 7, 7, 12, 0, 0));      /* EDT = UTC-4 */
    NEXT("0 8 * * 1", utc(2025, 12, 1, 14, 0, 0), utc(2025, 12, 8, 13, 0, 0));   /* EST = UTC-5 */
    setenv("TZ", "UTC", 1);
    tzset();
}

typedef struct { int slot; _Atomic int *seen; _Atomic int *total; _Atomic int *mine; } runner;

static void *runner_main(void *p) {
    runner *r = p;
    for (;;) {
        gs_buf b = {0};
        int64_t id = 0, att = 0;
        int got = gweb_jobs_take(r->slot, 200, &b, &id, &att, NULL);
        if (!got) { free(b.data); break; }
        int n = atoi(b.data);
        free(b.data);
        if (id >= 1 && id <= 1000) atomic_fetch_add(&r->seen[id], 1);
        (void)n;
        atomic_fetch_add(r->total, 1);
        atomic_fetch_add(r->mine, 1);
        gweb_jobs_done(r->slot, 1);
    }
    return NULL;
}

static void test_two_runners(void) {
    gweb_jobs_test_clock(NULL);
    gweb_jobs_init(2, 10000, 5);
    for (int i = 0; i < 600; i++) {
        char s[16];
        snprintf(s, sizeof s, "%d", i);
        gweb_jobs_push((gweb_bytes){(const uint8_t *)s, (int64_t)strlen(s)}, 0);
    }
    static _Atomic int seen[1001];
    _Atomic int total = 0, m0 = 0, m1 = 0;
    runner r0 = {0, seen, &total, &m0}, r1 = {1, seen, &total, &m1};
    pthread_t t0, t1;
    pthread_create(&t0, NULL, runner_main, &r0);
    pthread_create(&t1, NULL, runner_main, &r1);
    pthread_join(t0, NULL);
    pthread_join(t1, NULL);
    CHECK(total == 600);
    int dup = 0, missing = 0;
    for (int i = 1; i <= 600; i++) { if (seen[i] > 1) dup++; if (seen[i] == 0) missing++; }
    CHECK(dup == 0 && missing == 0);
    CHECK(gweb_jobs_stat(2) == 600 && gweb_jobs_stat(0) == 0 && gweb_jobs_stat(1) == 0);

    /* two runners holding at once get different jobs */
    gweb_jobs_init(2, 10, 5);
    gweb_jobs_push(S("x"), 0);
    gweb_jobs_push(S("y"), 0);
    int64_t i0, i1;
    CHECK(take(0, 0, NULL, &i0, NULL, NULL) == 1 && take(1, 0, NULL, &i1, NULL, NULL) == 1 && i0 != i1);
    CHECK(gweb_jobs_stat(1) == 2);
    gweb_jobs_done(0, 1);
    gweb_jobs_done(1, 1);
}

static void *blocked_take(void *p) {
    int *r = p;
    gs_buf b = {0};
    *r = gweb_jobs_take(0, 30000, &b, NULL, NULL, NULL);
    free(b.data);
    return NULL;
}

static void *late_push(void *p) {
    (void)p;
    usleep(100000);
    gweb_jobs_push(S("late"), 0);
    return NULL;
}

static void test_waiting_and_stop(void) {
    gweb_jobs_test_clock(NULL);
    gweb_jobs_init(1, 10, 5);
    char buf[64];
    int64_t t = mono_ms();
    CHECK(take(0, 150, buf, NULL, NULL, NULL) == 0);
    int64_t dt = mono_ms() - t;
    CHECK(dt >= 140 && dt < 1500);

    pthread_t th;
    pthread_create(&th, NULL, late_push, NULL);
    t = mono_ms();
    CHECK(take(0, 10000, buf, NULL, NULL, NULL) == 1 && strcmp(buf, "late") == 0);
    dt = mono_ms() - t;
    CHECK(dt >= 80 && dt < 3000);
    pthread_join(th, NULL);
    gweb_jobs_done(0, 1);

    gweb_jobs_push(S("d"), 200);
    t = mono_ms();
    CHECK(take(0, 5000, buf, NULL, NULL, NULL) == 1);
    dt = mono_ms() - t;
    CHECK(dt >= 180 && dt < 3000);
    gweb_jobs_done(0, 1);

    /* a schedule wakes a blocked take on time with the real clock */
    CHECK(gweb_jobs_every(S("rt"), 120, S("R")));
    char name[64];
    t = mono_ms();
    CHECK(take(0, 5000, buf, NULL, NULL, name) == 1 && strcmp(name, "rt") == 0);
    dt = mono_ms() - t;
    CHECK(dt >= 100 && dt < 3000);
    gweb_jobs_done(0, 1);

    /* stop wakes a blocked take at once */
    gweb_jobs_init(1, 10, 5);
    gweb_jobs_push(S("k"), 0);
    take(0, 0, buf, NULL, NULL, NULL);
    gweb_jobs_done(0, 1);
    gweb_jobs_push(S("z"), 60000);
    int r = -1;
    pthread_create(&th, NULL, blocked_take, &r);
    usleep(150000);
    t = mono_ms();
    gweb_jobs_stop();
    pthread_join(th, NULL);
    dt = mono_ms() - t;
    CHECK(r == 0 && dt < 1000);
    CHECK(gweb_jobs_push(S("z"), 0) == 0);
    CHECK(gweb_jobs_every(S("after"), 1000, S("a")) == 0);
    CHECK(gweb_jobs_cron(S("after2"), S("* * * * *"), S("a")) == 0);
    CHECK(take(0, 1000, buf, NULL, NULL, NULL) == 0);
    CHECK(gweb_jobs_stat(2) == 1 && gweb_jobs_stat(0) == 1);
    gweb_jobs_init(1, 10, 5); /* init clears the stop */
    CHECK(gweb_jobs_push(S("again"), 0) == 1);
}

int main(void) {
    test_fifo_and_delay();
    test_capacity();
    test_retry();
    test_every();
    test_cron_schedule();
    test_cron_table();
    test_cron_dst();
    test_two_runners();
    test_waiting_and_stop();
    return done();
}
