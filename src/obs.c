/* Process-wide observability state: clock, ids, the log writer and the metrics table. Everything here is
   callable from any thread; workers each own a slot of counters, so they never contend. */
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

#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/random.h>
#endif

int64_t gweb_now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

/* 2026-11-12T08:15:30.123Z */
void gweb_rfc3339(gs_rref out) {
    struct timespec ts;
    struct tm tm;
    char buf[40];
    clock_gettime(CLOCK_REALTIME, &ts);
    time_t t = ts.tv_sec;
    gmtime_r(&t, &tm);
    int n = snprintf(buf, sizeof buf, "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", tm.tm_year + 1900, tm.tm_mon + 1,
                     tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(ts.tv_nsec / 1000000));
    gs_bld_append(out, buf, n);
}

/* xoshiro256** */
static _Thread_local uint64_t rng_s[4];
static _Thread_local int rng_ready;

static uint64_t rotl(uint64_t x, int k) { return (x << k) | (x >> (64 - k)); }

static uint64_t splitmix(uint64_t *x) {
    uint64_t z = (*x += 0x9e3779b97f4a7c15ULL);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}

static void rng_seed(void) {
    if (getentropy(rng_s, sizeof rng_s) != 0) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        uint64_t x = (uint64_t)ts.tv_nsec ^ ((uint64_t)ts.tv_sec << 32) ^ (uint64_t)(uintptr_t)&ts ^ (uint64_t)getpid();
        for (int i = 0; i < 4; i++) rng_s[i] = splitmix(&x);
    }
    if ((rng_s[0] | rng_s[1] | rng_s[2] | rng_s[3]) == 0) rng_s[0] = 1;
    rng_ready = 1;
}

static uint64_t rng_next(void) {
    if (!rng_ready) rng_seed();
    uint64_t r = rotl(rng_s[1] * 5, 7) * 9;
    uint64_t t = rng_s[1] << 17;
    rng_s[2] ^= rng_s[0];
    rng_s[3] ^= rng_s[1];
    rng_s[1] ^= rng_s[2];
    rng_s[0] ^= rng_s[3];
    rng_s[2] ^= t;
    rng_s[3] = rotl(rng_s[3], 45);
    return r;
}

/* 2*nbytes lower-case hex digits; never all zeros (W3C trace and span ids must not be). */
void gweb_rand_hex(gs_rref out, int32_t nbytes) {
    static const char hex[] = "0123456789abcdef";
    char buf[16];
    int any = 0;
    while (nbytes > 0) {
        int chunk = nbytes < 8 ? nbytes : 8;
        uint64_t v = rng_next();
        for (int i = 0; i < chunk; i++) {
            uint8_t b = (uint8_t)(v >> (8 * i));
            if (nbytes == chunk && i == chunk - 1 && !any && b == 0) b = 1;
            if (b) any = 1;
            buf[2 * i] = hex[b >> 4];
            buf[2 * i + 1] = hex[b & 15];
        }
        gs_bld_append(out, buf, 2 * chunk);
        nbytes -= chunk;
    }
}

static _Atomic int log_level_v = 1;
static _Atomic int log_json_v;

void gweb_log_config(int32_t level, int32_t json) {
    atomic_store_explicit(&log_level_v, level, memory_order_relaxed);
    atomic_store_explicit(&log_json_v, json != 0, memory_order_relaxed);
}
int32_t gweb_log_level(void) { return atomic_load_explicit(&log_level_v, memory_order_relaxed); }
int32_t gweb_log_json(void) { return atomic_load_explicit(&log_json_v, memory_order_relaxed); }

static void write_all_fd(int fd, const char *p, size_t len) {
    while (len > 0) {
        ssize_t w = write(fd, p, len);
        if (w < 0) {
            if (errno == EINTR) continue;
            return;
        }
        p += w;
        len -= (size_t)w;
    }
}

/* One write per line so lines from several threads do not interleave; a missing newline is added. */
void gweb_log_line(gweb_bytes line) {
    if (line.len < 0) return;
    size_t n = (size_t)line.len;
    if (n > 0 && line.data[n - 1] == '\n') {
        write_all_fd(1, (const char *)line.data, n);
        return;
    }
    char stack[4096];
    char *buf = n + 1 <= sizeof stack ? stack : malloc(n + 1);
    if (!buf) {
        write_all_fd(1, (const char *)line.data, n);
        return;
    }
    if (n) memcpy(buf, line.data, n);
    buf[n] = '\n';
    write_all_fd(1, buf, n + 1);
    if (buf != stack) free(buf);
}

/* ---- metrics ---- */

#define NBUCKETS 13
#define NMETHODS 8
#define NCLASSES 5
#define PER_ROUTE (NMETHODS * NCLASSES + NBUCKETS + 1)
#define APP_MAX 256
#define APP_NAME_MAX 63

static const int64_t edge_us[NBUCKETS - 1] = {500,    1000,   2500,   5000,    10000,   25000,
                                              50000,  100000, 250000, 500000, 1000000, 2500000};
static const char *const edge_le[NBUCKETS] = {"0.0005", "0.001", "0.0025", "0.005", "0.01", "0.025", "0.05",
                                              "0.1",    "0.25",  "0.5",    "1",     "2.5",  "+Inf"};
static const char *const method_name[NMETHODS] = {"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "OTHER"};

typedef _Atomic uint64_t slot_t;

typedef struct {
    int workers;
    int routes;      /* patterns; slot routes is "static", routes + 1 is "-" */
    size_t stride;   /* slots per worker, a multiple of 8 so workers do not share a cache line */
    char *names;     /* patterns, NUL separated */
    size_t *name_off;
    slot_t *slots;
    double start_time;
} metrics_t;

/* worker block: [0] open connections, then per route: requests[method][class], buckets[NBUCKETS], sum_us */
static _Atomic(metrics_t *) g_m;

static slot_t *route_base(const metrics_t *m, int w, int r) { return m->slots + (size_t)w * m->stride + 1 + (size_t)r * PER_ROUTE; }

void gweb_metrics_init(int32_t workers, gweb_bytes route_names_nl) {
    if (workers < 1) workers = 1;
    metrics_t *m = calloc(1, sizeof *m);
    if (!m) return;
    const char *p = (const char *)route_names_nl.data;
    size_t len = route_names_nl.len > 0 ? (size_t)route_names_nl.len : 0;
    int routes = len ? 1 : 0;
    for (size_t i = 0; i < len; i++) if (p[i] == '\n') routes++;
    m->workers = workers;
    m->routes = routes;
    m->names = malloc(len + 1);
    m->name_off = malloc(sizeof(size_t) * (size_t)(routes + 1));
    size_t per = 1 + (size_t)(routes + 2) * PER_ROUTE;
    m->stride = (per + 7) & ~(size_t)7;
    void *mem = NULL;
    if (!m->names || !m->name_off || posix_memalign(&mem, 64, m->stride * (size_t)workers * sizeof(slot_t)) != 0) {
        free(m->names); free(m->name_off); free(m);
        return;
    }
    m->slots = mem;
    memset(mem, 0, m->stride * (size_t)workers * sizeof(slot_t));
    if (len) memcpy(m->names, p, len);
    m->names[len] = 0;
    int k = 0;
    if (routes) m->name_off[k++] = 0;
    for (size_t i = 0; i < len; i++) {
        if (p[i] == '\n') {
            m->names[i] = 0;
            m->name_off[k++] = i + 1;
        }
    }
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    m->start_time = (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
    /* Only call this while no worker is running; the old table is freed. */
    metrics_t *old = atomic_exchange_explicit(&g_m, m, memory_order_acq_rel);
    if (old) { free(old->names); free(old->name_off); free(old->slots); free(old); }
}

int32_t gweb_metrics_on(void) { return atomic_load_explicit(&g_m, memory_order_acquire) != NULL; }

/* route: pattern index, -2 static files, -1 no match. */
void gweb_metrics_request(int32_t worker, int32_t route, int32_t method, int32_t status, int64_t dur_us) {
    metrics_t *m = atomic_load_explicit(&g_m, memory_order_acquire);
    if (!m || worker < 0 || worker >= m->workers) return;
    int r = route == -2 ? m->routes : (route >= 0 && route < m->routes) ? route : m->routes + 1;
    if (method < 0 || method >= NMETHODS) method = NMETHODS - 1;
    int cls = status / 100 - 1;
    if (cls < 0 || cls >= NCLASSES) cls = NCLASSES - 1;
    if (dur_us < 0) dur_us = 0;
    int b = 0;
    while (b < NBUCKETS - 1 && dur_us > edge_us[b]) b++;
    slot_t *s = route_base(m, worker, r);
    atomic_fetch_add_explicit(&s[method * NCLASSES + cls], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&s[NMETHODS * NCLASSES + b], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&s[NMETHODS * NCLASSES + NBUCKETS], (uint64_t)dur_us, memory_order_relaxed);
}

void gweb_metrics_conn(int32_t worker, int64_t open_count) {
    metrics_t *m = atomic_load_explicit(&g_m, memory_order_acquire);
    if (!m || worker < 0 || worker >= m->workers) return;
    atomic_store_explicit(&m->slots[(size_t)worker * m->stride], (uint64_t)open_count, memory_order_relaxed);
}

/* app metrics */
typedef struct {
    char name[APP_NAME_MAX + 1];
    int is_gauge;
    _Atomic uint64_t val; /* counter: int64 count; gauge: double bits */
} app_t;

static app_t app_tab[APP_MAX];
static _Atomic int app_n;
static pthread_mutex_t app_mu = PTHREAD_MUTEX_INITIALIZER;
static _Atomic int app_warned;

static int name_ok(const char *s, size_t n) {
    if (n == 0 || n > APP_NAME_MAX) return 0;
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        if (!(c == '_' || (c >= 'a' && c <= 'z') || (i > 0 && c >= '0' && c <= '9'))) return 0;
    }
    /* the framework's own names are not the app's to take */
    return !(n >= 5 && memcmp(s, "gweb_", 5) == 0);
}

static int app_find(const char *s, size_t n, int upto) {
    for (int i = 0; i < upto; i++)
        if (strlen(app_tab[i].name) == n && memcmp(app_tab[i].name, s, n) == 0) return i;
    return -1;
}

static app_t *app_get(gweb_bytes name, int gauge) {
    const char *s = (const char *)name.data;
    size_t n = name.len > 0 ? (size_t)name.len : 0;
    int i = app_find(s, n, atomic_load_explicit(&app_n, memory_order_acquire));
    if (i < 0) {
        if (!name_ok(s, n)) return NULL;
        pthread_mutex_lock(&app_mu);
        int cur = atomic_load_explicit(&app_n, memory_order_relaxed);
        i = app_find(s, n, cur);
        if (i < 0) {
            if (cur >= APP_MAX) {
                pthread_mutex_unlock(&app_mu);
                if (!atomic_exchange(&app_warned, 1))
                    fprintf(stderr, "goose-web: more than %d app metric names; ignoring \"%.*s\" and any new ones\n", APP_MAX, (int)n, s);
                return NULL;
            }
            memcpy(app_tab[cur].name, s, n);
            app_tab[cur].name[n] = 0;
            app_tab[cur].is_gauge = gauge;
            atomic_store_explicit(&app_n, cur + 1, memory_order_release);
            i = cur;
        }
        pthread_mutex_unlock(&app_mu);
    }
    return app_tab[i].is_gauge == gauge ? &app_tab[i] : NULL;
}

void gweb_metric_count(gweb_bytes name, int64_t n) {
    if (!gweb_metrics_on()) return;
    app_t *a = app_get(name, 0);
    if (a) atomic_fetch_add_explicit(&a->val, (uint64_t)n, memory_order_relaxed);
}

void gweb_metric_gauge(gweb_bytes name, double v) {
    if (!gweb_metrics_on()) return;
    app_t *a = app_get(name, 1);
    if (!a) return;
    uint64_t bits;
    memcpy(&bits, &v, sizeof bits);
    atomic_store_explicit(&a->val, bits, memory_order_relaxed);
}

/* stubs; src/otel.c and src/jobs.c define the real ones */
__attribute__((weak)) int64_t gweb_jobs_stat(int32_t which) { (void)which; return 0; }
__attribute__((weak)) int64_t gweb_spans_dropped(void) { return 0; }

/* rendering */
static void put(gs_rref out, const char *s, size_t n) { if (n) gs_bld_append(out, s, (int64_t)n); }
static void puts_(gs_rref out, const char *s) { put(out, s, strlen(s)); }

static void putf(gs_rref out, const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n > 0) put(out, buf, (size_t)n < sizeof buf ? (size_t)n : sizeof buf - 1);
}

/* label value escaping: backslash, double quote, newline */
static void put_label(gs_rref out, const char *s, size_t n) {
    size_t run = 0;
    for (size_t i = 0; i < n; i++) {
        const char *rep = s[i] == '\\' ? "\\\\" : s[i] == '"' ? "\\\"" : s[i] == '\n' ? "\\n" : NULL;
        if (!rep) continue;
        put(out, s + run, i - run);
        puts_(out, rep);
        run = i + 1;
    }
    put(out, s + run, n - run);
}

static void put_double(gs_rref out, double v) {
    if (isnan(v)) puts_(out, "NaN");
    else if (isinf(v)) puts_(out, v > 0 ? "+Inf" : "-Inf");
    else putf(out, "%.17g", v);
}

static void head(gs_rref out, const char *name, const char *help, const char *type) {
    putf(out, "# HELP %s %s\n# TYPE %s %s\n", name, help, name, type);
}

static void simple(gs_rref out, const char *name, const char *help, const char *type, int64_t v) {
    head(out, name, help, type);
    putf(out, "%s %lld\n", name, (long long)v);
}

void gweb_metrics_render(gs_rref out, gweb_bytes version) {
    metrics_t *m = atomic_load_explicit(&g_m, memory_order_acquire);
    int routes = m ? m->routes : 0;

    head(out, "gweb_http_requests_total", "HTTP requests by route, method and status class.", "counter");
    for (int r = 0; m && r < routes + 2; r++) {
        const char *rn = r < routes ? m->names + m->name_off[r] : r == routes ? "static" : "-";
        for (int me = 0; me < NMETHODS; me++)
            for (int c = 0; c < NCLASSES; c++) {
                uint64_t sum = 0;
                for (int w = 0; w < m->workers; w++)
                    sum += atomic_load_explicit(&route_base(m, w, r)[me * NCLASSES + c], memory_order_relaxed);
                if (!sum) continue;
                puts_(out, "gweb_http_requests_total{route=\"");
                put_label(out, rn, strlen(rn));
                putf(out, "\",method=\"%s\",code=\"%dxx\"} %llu\n", method_name[me], c + 1, (unsigned long long)sum);
            }
    }

    head(out, "gweb_http_request_duration_seconds", "HTTP request duration by route.", "histogram");
    for (int r = 0; m && r < routes + 2; r++) {
        const char *rn = r < routes ? m->names + m->name_off[r] : r == routes ? "static" : "-";
        uint64_t b[NBUCKETS] = {0}, sum_us = 0, total = 0;
        for (int w = 0; w < m->workers; w++) {
            slot_t *s = route_base(m, w, r);
            for (int i = 0; i < NBUCKETS; i++) b[i] += atomic_load_explicit(&s[NMETHODS * NCLASSES + i], memory_order_relaxed);
            sum_us += atomic_load_explicit(&s[NMETHODS * NCLASSES + NBUCKETS], memory_order_relaxed);
        }
        for (int i = 0; i < NBUCKETS; i++) total += b[i];
        if (!total) continue;
        uint64_t cum = 0;
        for (int i = 0; i < NBUCKETS; i++) {
            cum += b[i];
            puts_(out, "gweb_http_request_duration_seconds_bucket{route=\"");
            put_label(out, rn, strlen(rn));
            putf(out, "\",le=\"%s\"} %llu\n", edge_le[i], (unsigned long long)cum);
        }
        puts_(out, "gweb_http_request_duration_seconds_sum{route=\"");
        put_label(out, rn, strlen(rn));
        putf(out, "\"} %.6f\n", (double)sum_us / 1e6);
        puts_(out, "gweb_http_request_duration_seconds_count{route=\"");
        put_label(out, rn, strlen(rn));
        putf(out, "\"} %llu\n", (unsigned long long)total);
    }

    int64_t open = 0;
    for (int w = 0; m && w < m->workers; w++)
        open += (int64_t)atomic_load_explicit(&m->slots[(size_t)w * m->stride], memory_order_relaxed);
    simple(out, "gweb_http_connections_open", "Open HTTP connections.", "gauge", open);

    simple(out, "gweb_jobs_queued", "Jobs waiting to run.", "gauge", gweb_jobs_stat(0));
    simple(out, "gweb_jobs_running", "Jobs running now.", "gauge", gweb_jobs_stat(1));
    simple(out, "gweb_jobs_completed_total", "Jobs that finished successfully.", "counter", gweb_jobs_stat(2));
    simple(out, "gweb_jobs_failed_total", "Failed job attempts.", "counter", gweb_jobs_stat(3));
    simple(out, "gweb_jobs_dropped_total", "Jobs dropped at shutdown.", "counter", gweb_jobs_stat(4));
    simple(out, "gweb_jobs_rejected_total", "Jobs refused because the queue was full.", "counter", gweb_jobs_stat(5));
    simple(out, "gweb_spans_dropped_total", "Spans dropped because the export ring was full.", "counter", gweb_spans_dropped());

    head(out, "gweb_process_start_time_seconds", "Start time of the process, Unix seconds.", "gauge");
    putf(out, "gweb_process_start_time_seconds %.3f\n", m ? m->start_time : 0.0);
    head(out, "gweb_build_info", "Build information.", "gauge");
    puts_(out, "gweb_build_info{version=\"");
    put_label(out, (const char *)version.data, version.len > 0 ? (size_t)version.len : 0);
    puts_(out, "\"} 1\n");

    int n = atomic_load_explicit(&app_n, memory_order_acquire);
    for (int i = 0; i < n; i++) {
        const app_t *a = &app_tab[i];
        uint64_t v = atomic_load_explicit(&a->val, memory_order_relaxed);
        head(out, a->name, a->is_gauge ? "App gauge." : "App counter.", a->is_gauge ? "gauge" : "counter");
        puts_(out, a->name);
        puts_(out, " ");
        if (a->is_gauge) {
            double d;
            memcpy(&d, &v, sizeof d);
            put_double(out, d);
        } else {
            putf(out, "%lld", (long long)v);
        }
        puts_(out, "\n");
    }
}
