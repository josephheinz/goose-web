/* Background job queue and scheduler: one mutex and condition variable. Job bytes live in C memory, so the
   queue survives the abort of a runner thread. All times are unix milliseconds from one clock (injectable). */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#ifdef __APPLE__
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#endif

#include "goose.h"
#include "ops.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define NAME_MAX_LEN 32
#define SPEC_MAX_LEN 127
#define RETRY_BASE_MS 1000
#define RETRY_MAX_MS 300000
#define TEST_WAIT_CAP_MS 50
#define CRON_HORIZON_S (5LL * 366 * 86400)

/* ---- cron ---- */

typedef struct {
    uint64_t min;
    uint32_t hour, dom, mon, dow; /* dow bits 0..6, Sunday 0 */
    int dom_star, dow_star;
} cron_spec;

static int parse_num(const char *s, int n, int *pos, int *out) {
    int v = 0, start = *pos;
    while (*pos < n && s[*pos] >= '0' && s[*pos] <= '9') {
        v = v * 10 + (s[*pos] - '0');
        if (v > 1000) return 0;
        (*pos)++;
    }
    if (*pos == start) return 0;
    *out = v;
    return 1;
}

/* One comma-separated field into a bit set over lo..hi. */
static int parse_field(const char *s, int n, int lo, int hi, uint64_t *bits) {
    *bits = 0;
    int pos = 0;
    if (n == 0) return 0;
    for (;;) {
        int a, b, step = 1;
        if (pos < n && s[pos] == '*') {
            a = lo; b = hi; pos++;
            if (pos < n && s[pos] == '/') {
                pos++;
                if (!parse_num(s, n, &pos, &step) || step < 1) return 0;
            }
        } else {
            if (!parse_num(s, n, &pos, &a)) return 0;
            b = a;
            if (pos < n && s[pos] == '-') {
                pos++;
                if (!parse_num(s, n, &pos, &b)) return 0;
                if (pos < n && s[pos] == '/') {
                    pos++;
                    if (!parse_num(s, n, &pos, &step) || step < 1) return 0;
                }
            }
        }
        if (a < lo || b > hi || a > b) return 0;
        for (int v = a; v <= b; v += step) *bits |= 1ULL << v;
        if (pos == n) return 1;
        if (s[pos] != ',') return 0;
        pos++;
    }
}

static int cron_parse(const uint8_t *spec, int64_t len, cron_spec *c) {
    if (len < 0 || len > SPEC_MAX_LEN) return 0;
    const char *s = (const char *)spec;
    int start[5], flen[5], nf = 0, i = 0;
    while (i < len) {
        while (i < len && (s[i] == ' ' || s[i] == '\t')) i++;
        if (i >= len) break;
        if (nf == 5) return 0;
        start[nf] = i;
        while (i < len && s[i] != ' ' && s[i] != '\t') i++;
        flen[nf] = i - start[nf];
        nf++;
    }
    if (nf != 5) return 0;
    uint64_t m, h, dom, mon, dow;
    if (!parse_field(s + start[0], flen[0], 0, 59, &m)) return 0;
    if (!parse_field(s + start[1], flen[1], 0, 23, &h)) return 0;
    if (!parse_field(s + start[2], flen[2], 1, 31, &dom)) return 0;
    if (!parse_field(s + start[3], flen[3], 1, 12, &mon)) return 0;
    if (!parse_field(s + start[4], flen[4], 0, 7, &dow)) return 0;
    if (dow & 128) dow = (dow | 1) & 127;
    c->min = m; c->hour = (uint32_t)h; c->dom = (uint32_t)dom; c->mon = (uint32_t)mon; c->dow = (uint32_t)dow;
    /* as in Vixie cron, a field that starts with '*' counts as unrestricted for the dom/dow rule */
    c->dom_star = s[start[2]] == '*';
    c->dow_star = s[start[4]] == '*';
    return 1;
}

static int is_leap(int y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0; }
static int days_in(int y, int mo) {
    static const int d[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    return mo == 2 && is_leap(y) ? 29 : d[mo - 1];
}
static int weekday(int y, int mo, int d) { /* 0 Sunday */
    static const int t[12] = {0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4};
    if (mo < 3) y--;
    return (y + y / 4 - y / 100 + y / 400 + t[mo - 1] + d) % 7;
}

static int day_ok(const cron_spec *c, int y, int mo, int d) {
    int dm = (c->dom >> d) & 1, dw = (c->dow >> weekday(y, mo, d)) & 1;
    return (c->dom_star || c->dow_star) ? (dm && dw) : (dm || dw);
}

/* Local wall time to unix seconds. A wall time that occurs twice (clocks go back) maps to its first
   occurrence; one that does not exist (clocks go forward) yields -1, so that minute is skipped. */
static int64_t wall_to_unix(int y, int mo, int d, int h, int mi) {
    int64_t best = -1;
    for (int dst = -1; dst <= 1; dst++) {
        struct tm tm = {0}, chk;
        tm.tm_year = y - 1900; tm.tm_mon = mo - 1; tm.tm_mday = d; tm.tm_hour = h; tm.tm_min = mi;
        tm.tm_isdst = dst;
        time_t t = mktime(&tm);
        if (t == (time_t)-1) continue;
        if (!localtime_r(&t, &chk)) continue;
        if (chk.tm_year != y - 1900 || chk.tm_mon != mo - 1 || chk.tm_mday != d || chk.tm_hour != h || chk.tm_min != mi) continue;
        if (best < 0 || t < best) best = t;
    }
    return best;
}

static int64_t cron_next_c(const cron_spec *c, int64_t after) {
    tzset();
    int64_t s = after - (((after % 60) + 60) % 60) + 60;
    time_t ts = (time_t)s;
    struct tm w;
    if (!localtime_r(&ts, &w)) return -1;
    int y = w.tm_year + 1900, mo = w.tm_mon + 1, d = w.tm_mday, h = w.tm_hour, mi = w.tm_min;
    int limit = y + 6;
    for (;;) {
        if (y > limit) return -1;
        if (mo > 12) { mo = 1; y++; d = 1; h = 0; mi = 0; continue; }
        if (!((c->mon >> mo) & 1)) { mo++; d = 1; h = 0; mi = 0; continue; }
        if (d > days_in(y, mo)) { mo++; d = 1; h = 0; mi = 0; continue; }
        if (!day_ok(c, y, mo, d)) { d++; h = 0; mi = 0; continue; }
        if (h > 23) { d++; h = 0; mi = 0; continue; }
        if (!((c->hour >> h) & 1)) { h++; mi = 0; continue; }
        if (mi > 59) { h++; mi = 0; continue; }
        if (!((c->min >> mi) & 1)) { mi++; continue; }
        int64_t t = wall_to_unix(y, mo, d, h, mi);
        if (t > after) return t - after > CRON_HORIZON_S ? -1 : t;
        mi++;
    }
}

int64_t gweb_cron_next(gweb_bytes spec, int64_t after_unix) {
    cron_spec c;
    if (!cron_parse(spec.data, spec.len, &c)) return -1;
    return cron_next_c(&c, after_unix);
}

/* ---- queue ---- */

typedef struct job {
    struct job *next;
    uint8_t *data;
    int64_t len, id, not_before;
    int32_t attempt, sched;
} job;

typedef struct {
    char name[NAME_MAX_LEN + 1];
    int is_cron;
    int64_t every_ms, next_due;
    char spec[SPEC_MAX_LEN + 1];
    uint8_t *data;
    int64_t len;
    int live; /* its jobs queued or running */
} sched;

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static int inited, stopped, max_attempts;
static int64_t cap, qn, next_id, stats[6]; /* stats[0] unused: queued is qn */
static job *head, *tail, **cur;
static int nslots;
static sched *scheds;
static int nscheds;
static int64_t (*clock_fn)(void);

static int64_t real_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static int64_t now_ms(void) { return clock_fn ? clock_fn() : real_now_ms(); }

static void free_job(job *j) { free(j->data); free(j); }

static void reset_locked(void) {
    for (job *j = head, *n; j; j = n) { n = j->next; free_job(j); }
    head = tail = NULL;
    for (int i = 0; i < nslots; i++) if (cur[i]) free_job(cur[i]);
    free(cur);
    cur = NULL;
    for (int i = 0; i < nscheds; i++) free(scheds[i].data);
    free(scheds);
    scheds = NULL;
    nscheds = 0;
    qn = 0;
    memset(stats, 0, sizeof stats);
}

void gweb_jobs_init(int32_t runners, int64_t capacity, int32_t attempts) {
    pthread_mutex_lock(&mu);
    reset_locked();
    nslots = runners < 1 ? 1 : runners;
    cur = calloc((size_t)nslots, sizeof *cur);
    cap = capacity < 0 ? 0 : capacity;
    max_attempts = attempts < 1 ? 1 : attempts;
    next_id = 1;
    stopped = 0;
    inited = 1;
    pthread_mutex_unlock(&mu);
}

void gweb_jobs_test_clock(int64_t (*fn)(void)) {
    pthread_mutex_lock(&mu);
    clock_fn = fn;
    pthread_cond_broadcast(&cv);
    pthread_mutex_unlock(&mu);
}

void gweb_jobs_test_kick(void) {
    pthread_mutex_lock(&mu);
    pthread_cond_broadcast(&cv);
    pthread_mutex_unlock(&mu);
}

static void enqueue_locked(job *j) {
    j->next = NULL;
    if (tail) tail->next = j; else head = j;
    tail = j;
    qn++;
}

static job *new_job(const uint8_t *data, int64_t len, int64_t not_before, int sched_idx) {
    job *j = calloc(1, sizeof *j);
    if (!j) return NULL;
    j->data = malloc(len > 0 ? (size_t)len : 1);
    if (!j->data) { free(j); return NULL; }
    if (len > 0) memcpy(j->data, data, (size_t)len);
    j->len = len > 0 ? len : 0;
    j->id = next_id++;
    j->attempt = 1;
    j->not_before = not_before;
    j->sched = sched_idx;
    return j;
}

int32_t gweb_jobs_push(gweb_bytes bytes, int64_t delay_ms) {
    pthread_mutex_lock(&mu);
    int ok = 0;
    if (inited && !stopped && delay_ms >= 0 && bytes.len >= 0) {
        if (qn >= cap) stats[5]++;
        else {
            job *j = new_job(bytes.data, bytes.len, now_ms() + delay_ms, -1);
            if (j) { enqueue_locked(j); ok = 1; pthread_cond_broadcast(&cv); }
        }
    }
    pthread_mutex_unlock(&mu);
    return ok;
}

static int64_t backoff_ms(int attempt) {
    int64_t d = RETRY_BASE_MS;
    for (int i = 1; i < attempt && d < RETRY_MAX_MS; i++) d *= 2;
    return d < RETRY_MAX_MS ? d : RETRY_MAX_MS;
}

static void finish_locked(job *j, int ok) {
    if (ok) { stats[2]++; if (j->sched >= 0) scheds[j->sched].live--; free_job(j); return; }
    stats[3]++;
    if (!stopped && j->attempt < max_attempts) {
        j->not_before = now_ms() + backoff_ms(j->attempt);
        j->attempt++;
        enqueue_locked(j);
        pthread_cond_broadcast(&cv);
        return;
    }
    stats[4]++;
    if (stopped) fprintf(stderr, "error: job %lld dropped at shutdown after %d attempt(s)\n", (long long)j->id, (int)j->attempt);
    else fprintf(stderr, "error: job %lld dropped after %d attempts\n", (long long)j->id, (int)j->attempt);
    if (j->sched >= 0) scheds[j->sched].live--;
    free_job(j);
}

void gweb_jobs_done(int32_t slot, int32_t ok) {
    pthread_mutex_lock(&mu);
    if (slot >= 0 && slot < nslots && cur[slot]) {
        job *j = cur[slot];
        cur[slot] = NULL;
        finish_locked(j, ok != 0);
    }
    pthread_mutex_unlock(&mu);
}

int32_t gweb_jobs_abandon(int32_t slot) {
    int had = 0;
    pthread_mutex_lock(&mu);
    if (slot >= 0 && slot < nslots && cur[slot]) {
        job *j = cur[slot];
        cur[slot] = NULL;
        finish_locked(j, 0);
        had = 1;
    }
    pthread_mutex_unlock(&mu);
    return had;
}

/* ---- schedules ---- */

static int add_sched(gweb_bytes name, int is_cron, int64_t every_ms, const cron_spec *c, gweb_bytes spec, gweb_bytes bytes) {
    if (name.len < 1 || name.len > NAME_MAX_LEN || bytes.len < 0) return 0;
    pthread_mutex_lock(&mu);
    int ok = 0;
    if (inited && !stopped) {
        int dup = 0;
        for (int i = 0; i < nscheds; i++)
            if ((int64_t)strlen(scheds[i].name) == name.len && memcmp(scheds[i].name, name.data, (size_t)name.len) == 0) dup = 1;
        int64_t now = now_ms(), due = 0;
        if (is_cron) due = cron_next_c(c, now / 1000);
        else due = now + every_ms;
        if (!dup && due >= 0) {
            sched *n = realloc(scheds, (size_t)(nscheds + 1) * sizeof *scheds);
            uint8_t *data = malloc(bytes.len > 0 ? (size_t)bytes.len : 1);
            if (n && data) {
                scheds = n;
                sched *s = &scheds[nscheds];
                memset(s, 0, sizeof *s);
                memcpy(s->name, name.data, (size_t)name.len);
                s->is_cron = is_cron;
                s->every_ms = every_ms;
                if (is_cron) memcpy(s->spec, spec.data, (size_t)spec.len);
                s->next_due = is_cron ? due * 1000 : due;
                if (bytes.len > 0) memcpy(data, bytes.data, (size_t)bytes.len);
                s->data = data;
                s->len = bytes.len;
                nscheds++;
                ok = 1;
                pthread_cond_broadcast(&cv);
            } else free(data);
        }
    }
    pthread_mutex_unlock(&mu);
    return ok;
}

int32_t gweb_jobs_every(gweb_bytes name, int64_t ms, gweb_bytes bytes) {
    if (ms < 1) return 0;
    return add_sched(name, 0, ms, NULL, (gweb_bytes){0}, bytes);
}

int32_t gweb_jobs_cron(gweb_bytes name, gweb_bytes spec, gweb_bytes bytes) {
    cron_spec c;
    if (!cron_parse(spec.data, spec.len, &c)) return 0;
    return add_sched(name, 1, 0, &c, spec, bytes);
}

static void fire_due_locked(int64_t now) {
    for (int i = 0; i < nscheds; i++) {
        sched *s = &scheds[i];
        if (s->next_due > now) continue;
        if (s->is_cron) {
            cron_spec c;
            int64_t nx = cron_parse((const uint8_t *)s->spec, (int64_t)strlen(s->spec), &c) ? cron_next_c(&c, now / 1000) : -1;
            s->next_due = nx < 0 ? INT64_MAX : nx * 1000;
        } else {
            s->next_due += s->every_ms;
            if (s->next_due <= now) s->next_due = now + s->every_ms;
        }
        if (s->live > 0) {
            fprintf(stderr, "warn: schedule \"%s\" skipped, its previous job is still queued or running\n", s->name);
            continue;
        }
        if (qn >= cap) {
            stats[5]++;
            fprintf(stderr, "warn: schedule \"%s\" skipped, the job queue is full\n", s->name);
            continue;
        }
        job *j = new_job(s->data, s->len, now, i);
        if (!j) continue;
        s->live++;
        enqueue_locked(j);
    }
}

/* ---- take ---- */

int32_t gweb_jobs_take(int32_t slot, int64_t timeout_ms, gs_rref out, int64_t *id, int64_t *attempt, gs_rref sched_name_out) {
    int got = 0;
    pthread_mutex_lock(&mu);
    if (!inited || slot < 0 || slot >= nslots) { pthread_mutex_unlock(&mu); return 0; }
    if (cur[slot]) { job *p = cur[slot]; cur[slot] = NULL; finish_locked(p, 0); }
    int64_t deadline = now_ms() + (timeout_ms > 0 ? timeout_ms : 0);
    for (;;) {
        if (stopped) break;
        int64_t now = now_ms();
        fire_due_locked(now);
        job *prev = NULL, *j = NULL;
        int64_t wake = deadline;
        for (job *p = head, *pp = NULL; p; pp = p, p = p->next) {
            if (p->not_before <= now) { j = p; prev = pp; break; }
            if (p->not_before < wake) wake = p->not_before;
        }
        if (j) {
            if (prev) prev->next = j->next; else head = j->next;
            if (tail == j) tail = prev;
            qn--;
            j->next = NULL;
            cur[slot] = j;
            gs_bld_append(out, j->data, j->len);
            if (id) *id = j->id;
            if (attempt) *attempt = j->attempt;
            if (j->sched >= 0 && sched_name_out) gs_bld_append(sched_name_out, scheds[j->sched].name, (int64_t)strlen(scheds[j->sched].name));
            got = 1;
            break;
        }
        for (int i = 0; i < nscheds; i++) if (scheds[i].next_due < wake) wake = scheds[i].next_due;
        if (now >= deadline) break;
        int64_t wait = wake - now;
        if (wait < 1) wait = 1;
        if (clock_fn && wait > TEST_WAIT_CAP_MS) wait = TEST_WAIT_CAP_MS;
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        int64_t ns = (int64_t)ts.tv_nsec + (wait % 1000) * 1000000;
        ts.tv_sec += wait / 1000 + ns / 1000000000;
        ts.tv_nsec = (long)(ns % 1000000000);
        pthread_cond_timedwait(&cv, &mu, &ts);
    }
    pthread_mutex_unlock(&mu);
    return got;
}

void gweb_jobs_stop(void) {
    pthread_mutex_lock(&mu);
    stopped = 1;
    pthread_cond_broadcast(&cv);
    pthread_mutex_unlock(&mu);
}

int64_t gweb_jobs_stat(int32_t which) {
    int64_t v = 0;
    pthread_mutex_lock(&mu);
    if (which == 0) v = qn;
    else if (which == 1) { for (int i = 0; i < nslots; i++) if (cur && cur[i]) v++; }
    else if (which >= 2 && which <= 5) v = stats[which];
    pthread_mutex_unlock(&mu);
    return v;
}
