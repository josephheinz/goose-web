/* Tracing: W3C Trace Context helpers, a ring of finished spans and an exporter thread that POSTs them as
   OTLP/HTTP JSON to a collector over plain HTTP. Callable from any thread. */
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
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/types.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

#define RING_CAP 8192
#define BATCH_MAX 512
#define IO_TIMEOUT_MS 2000
#define MAX_HEADERS_LEN 4096

int64_t gweb_unix_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static int is_lower_hex(const uint8_t *p, int n) {
    for (int i = 0; i < n; i++)
        if (!((p[i] >= '0' && p[i] <= '9') || (p[i] >= 'a' && p[i] <= 'f'))) return 0;
    return 1;
}

static int all_zero(const uint8_t *p, int n) {
    for (int i = 0; i < n; i++)
        if (p[i] != '0') return 0;
    return 1;
}

static int hex_val(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* version 00 only: 00-<32 hex>-<16 hex>-<2 hex flags>, lower-case, ids not all zero. */
int32_t gweb_trace_parse(gweb_bytes header, gs_rref trace_out, gs_rref parent_out, int32_t *sampled) {
    const uint8_t *h = header.data;
    if (header.len != 55 || !h) return 0;
    if (h[0] != '0' || h[1] != '0' || h[2] != '-' || h[35] != '-' || h[52] != '-') return 0;
    if (!is_lower_hex(h + 3, 32) || !is_lower_hex(h + 36, 16) || !is_lower_hex(h + 53, 2)) return 0;
    if (all_zero(h + 3, 32) || all_zero(h + 36, 16)) return 0;
    gs_bld_append(trace_out, h + 3, 32);
    gs_bld_append(parent_out, h + 36, 16);
    if (sampled) *sampled = (hex_val(h[54]) & 1) ? 1 : 0;
    return 1;
}

/* TraceIdRatioBased: the lower 8 bytes of the trace id (big-endian) against ratio * 2^64. */
int32_t gweb_trace_ratio_sampled(gweb_bytes trace_id, double ratio) {
    if (!(ratio > 0)) return 0;
    if (ratio >= 1) return 1;
    if (trace_id.len != 32) return 0;
    uint64_t v = 0;
    for (int i = 16; i < 32; i++) {
        int d = hex_val(trace_id.data[i]);
        if (d < 0) return 0;
        v = (v << 4) | (uint64_t)d;
    }
    uint64_t limit = (uint64_t)(ratio * 18446744073709551616.0);
    return v < limit;
}

int32_t gweb_trace_start(int32_t parent_sampled, gweb_bytes trace_id, double ratio) {
    if (parent_sampled >= 0) return parent_sampled != 0;
    return gweb_trace_ratio_sampled(trace_id, ratio);
}

void gweb_traceparent(gs_rref out, gweb_bytes trace, gweb_bytes span, int32_t sampled) {
    gs_bld_append(out, "00-", 3);
    gs_bld_append(out, trace.data, trace.len);
    gs_bld_append(out, "-", 1);
    gs_bld_append(out, span.data, span.len);
    gs_bld_append(out, sampled ? "-01" : "-00", 3);
}

/* ---- sampler configuration ---- */

static _Atomic int otel_on_v;
static _Atomic int otel_parent_v = 1;
static _Atomic double otel_ratio_v = 1.0;

int32_t gweb_otel_on(void) { return atomic_load_explicit(&otel_on_v, memory_order_relaxed); }
double gweb_otel_ratio(void) { return atomic_load_explicit(&otel_ratio_v, memory_order_relaxed); }
int32_t gweb_otel_parent_based(void) { return atomic_load_explicit(&otel_parent_v, memory_order_relaxed); }

/* The configured decision: a parent's flag wins only when the sampler is parent-based. */
int32_t gweb_otel_sample(int32_t parent_sampled, gweb_bytes trace_id) {
    if (!gweb_otel_on()) return 0;
    if (!gweb_otel_parent_based()) parent_sampled = -1;
    return gweb_trace_start(parent_sampled, trace_id, gweb_otel_ratio());
}

/* ---- span ring ---- */

typedef struct {
    uint8_t trace[16], span[8], parent[8];
    uint8_t has_parent, kind, status;
    uint8_t attr_is_int;
    int32_t http_status;
    int64_t start_ns, end_ns;
    uint16_t name_len, method_len, route_len, path_len, key_len, val_len;
    char name[128], method[16], route[128], path[256], key[32], val[64];
} span_rec;

static span_rec ring[RING_CAP];
static int ring_head, ring_count;
static _Atomic int64_t spans_dropped;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;

int64_t gweb_spans_dropped(void) { return atomic_load_explicit(&spans_dropped, memory_order_relaxed); }

static int hex_to_bytes(gweb_bytes h, uint8_t *out, int nbytes) {
    if (h.len != 2 * nbytes) return 0;
    for (int i = 0; i < nbytes; i++) {
        int a = hex_val(h.data[2 * i]), b = hex_val(h.data[2 * i + 1]);
        if (a < 0 || b < 0) return 0;
        out[i] = (uint8_t)(a << 4 | b);
    }
    return 1;
}

/* copies up to max bytes, not splitting a UTF-8 sequence */
static uint16_t copy_trunc(char *dst, int max, gweb_bytes s) {
    int64_t n = s.len < 0 ? 0 : s.len;
    if (!s.data) n = 0;
    if (n > max) {
        n = max;
        while (n > 0 && ((uint8_t)s.data[n] & 0xC0) == 0x80) n--;
    }
    if (n) memcpy(dst, s.data, (size_t)n);
    return (uint16_t)n;
}

/* Returns 1 when stored, 0 when dropped (full ring, or ids that are not hex of the right length; both counted).
   parent: empty for a root span. kind: 1 internal, 2 server. status: 0 unset, 2 error.
   method, route, path: empty to omit. http_status: 0 to omit.
   One generic attribute: attr_key empty to omit; with attr_is_int the value text is a decimal exported as an
   int (e.g. "job.attempt" "2"), otherwise a string. */
int32_t gweb_span_push(gweb_bytes trace, gweb_bytes span, gweb_bytes parent, gweb_bytes name, int32_t kind,
                       int64_t start_ns, int64_t end_ns, int32_t status, gweb_bytes method, gweb_bytes route,
                       gweb_bytes path, int32_t http_status, gweb_bytes attr_key, gweb_bytes attr_val,
                       int32_t attr_is_int) {
    span_rec r;
    memset(&r, 0, sizeof r);
    if (!hex_to_bytes(trace, r.trace, 16) || !hex_to_bytes(span, r.span, 8)) {
        atomic_fetch_add_explicit(&spans_dropped, 1, memory_order_relaxed);
        return 0;
    }
    r.has_parent = parent.len > 0 && hex_to_bytes(parent, r.parent, 8);
    r.kind = (uint8_t)kind;
    r.status = (uint8_t)status;
    r.start_ns = start_ns;
    r.end_ns = end_ns;
    r.http_status = http_status;
    r.name_len = copy_trunc(r.name, sizeof r.name, name);
    r.method_len = copy_trunc(r.method, sizeof r.method, method);
    r.route_len = copy_trunc(r.route, sizeof r.route, route);
    r.path_len = copy_trunc(r.path, sizeof r.path, path);
    r.key_len = copy_trunc(r.key, sizeof r.key, attr_key);
    r.val_len = copy_trunc(r.val, sizeof r.val, attr_val);
    r.attr_is_int = attr_is_int != 0;
    pthread_mutex_lock(&mu);
    if (ring_count == RING_CAP) {
        pthread_mutex_unlock(&mu);
        atomic_fetch_add_explicit(&spans_dropped, 1, memory_order_relaxed);
        return 0;
    }
    ring[(ring_head + ring_count) % RING_CAP] = r;
    ring_count++;
    if (ring_count >= BATCH_MAX) pthread_cond_signal(&cv);
    pthread_mutex_unlock(&mu);
    return 1;
}

/* ---- JSON ---- */

typedef struct { char *p; size_t len, cap; int oom; } jbuf;

static void jput(jbuf *b, const char *s, size_t n) {
    if (b->oom) return;
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 4096;
        while (cap < b->len + n + 1) cap *= 2;
        char *q = realloc(b->p, cap);
        if (!q) { b->oom = 1; return; }
        b->p = q;
        b->cap = cap;
    }
    memcpy(b->p + b->len, s, n);
    b->len += n;
    b->p[b->len] = 0;
}
static void jstr(jbuf *b, const char *s) { jput(b, s, strlen(s)); }

static void jprintf(jbuf *b, const char *fmt, long long v) {
    char t[64];
    int n = snprintf(t, sizeof t, fmt, v);
    jput(b, t, (size_t)n);
}

/* A JSON string; control bytes become \u00XX and invalid UTF-8 becomes U+FFFD, so the output always parses. */
static void jquote(jbuf *b, const char *s, size_t n) {
    jput(b, "\"", 1);
    size_t i = 0;
    while (i < n) {
        uint8_t c = (uint8_t)s[i];
        if (c == '"' || c == '\\') { char t[2] = {'\\', (char)c}; jput(b, t, 2); i++; }
        else if (c < 0x20 || c == 0x7f) { char t[8]; int k = snprintf(t, sizeof t, "\\u%04x", c); jput(b, t, (size_t)k); i++; }
        else if (c < 0x80) { jput(b, s + i, 1); i++; }
        else {
            size_t need = c >= 0xF0 && c <= 0xF4 ? 4 : c >= 0xE0 ? 3 : c >= 0xC2 && c < 0xE0 ? 2 : 0;
            int ok = need && i + need <= n;
            for (size_t k = 1; ok && k < need; k++) ok = ((uint8_t)s[i + k] & 0xC0) == 0x80;
            if (ok && need == 3) {
                uint8_t c1 = (uint8_t)s[i + 1];
                if ((c == 0xE0 && c1 < 0xA0) || (c == 0xED && c1 >= 0xA0)) ok = 0;
            }
            if (ok && need == 4) {
                uint8_t c1 = (uint8_t)s[i + 1];
                if ((c == 0xF0 && c1 < 0x90) || (c == 0xF4 && c1 >= 0x90)) ok = 0;
            }
            if (c >= 0xF5 || c == 0xC0 || c == 0xC1) ok = 0;
            if (ok) { jput(b, s + i, need); i += need; }
            else { jstr(b, "\\ufffd"); i++; }
        }
    }
    jput(b, "\"", 1);
}

static void jhex(jbuf *b, const uint8_t *p, int n) {
    static const char hx[] = "0123456789abcdef";
    char t[34];
    for (int i = 0; i < n; i++) { t[2 * i] = hx[p[i] >> 4]; t[2 * i + 1] = hx[p[i] & 15]; }
    jput(b, "\"", 1);
    jput(b, t, (size_t)(2 * n));
    jput(b, "\"", 1);
}

static void attr_str(jbuf *b, int *first, const char *key, const char *v, size_t vn) {
    if (!*first) jput(b, ",", 1);
    *first = 0;
    jstr(b, "{\"key\":");
    jquote(b, key, strlen(key));
    jstr(b, ",\"value\":{\"stringValue\":");
    jquote(b, v, vn);
    jstr(b, "}}");
}

static void attr_int(jbuf *b, int *first, const char *key, const char *digits) {
    if (!*first) jput(b, ",", 1);
    *first = 0;
    jstr(b, "{\"key\":");
    jquote(b, key, strlen(key));
    jstr(b, ",\"value\":{\"intValue\":\"");
    jstr(b, digits);
    jstr(b, "\"}}");
}

static void span_json(jbuf *b, const span_rec *r) {
    int first = 1;
    jstr(b, "{\"traceId\":");
    jhex(b, r->trace, 16);
    jstr(b, ",\"spanId\":");
    jhex(b, r->span, 8);
    if (r->has_parent) { jstr(b, ",\"parentSpanId\":"); jhex(b, r->parent, 8); }
    jstr(b, ",\"name\":");
    jquote(b, r->name, r->name_len);
    jprintf(b, ",\"kind\":%lld", r->kind);
    jstr(b, ",\"startTimeUnixNano\":\"");
    jprintf(b, "%lld", r->start_ns);
    jstr(b, "\",\"endTimeUnixNano\":\"");
    jprintf(b, "%lld", r->end_ns);
    jstr(b, "\",\"attributes\":[");
    if (r->method_len) attr_str(b, &first, "http.request.method", r->method, r->method_len);
    if (r->route_len) attr_str(b, &first, "http.route", r->route, r->route_len);
    if (r->path_len) attr_str(b, &first, "url.path", r->path, r->path_len);
    if (r->http_status) {
        char d[16];
        snprintf(d, sizeof d, "%d", r->http_status);
        attr_int(b, &first, "http.response.status_code", d);
    }
    if (r->key_len) {
        char key[40], val[72];
        memcpy(key, r->key, r->key_len); key[r->key_len] = 0;
        memcpy(val, r->val, r->val_len); val[r->val_len] = 0;
        char *end;
        strtoll(val, &end, 10);
        if (r->attr_is_int && r->val_len && !*end) attr_int(b, &first, key, val);
        else attr_str(b, &first, key, r->val, r->val_len);
    }
    jput(b, "]", 1);
    if (r->status == 2) jstr(b, ",\"status\":{\"code\":2}");
    jput(b, "}", 1);
}

/* ---- exporter ---- */

typedef struct {
    char host[256], port[8], path[512], service[128];
    char headers[MAX_HEADERS_LEN]; /* "Name: value\r\n" lines */
} export_cfg;

static pthread_t exp_thread;
static int exp_running, exp_stopping, exp_done;
static unsigned exp_gen;

static int64_t mono_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int connect_to(const export_cfg *c) {
    struct addrinfo hints, *res = NULL, *ai;
    memset(&hints, 0, sizeof hints);
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(c->host, c->port, &hints, &res) != 0) return -1;
    int fd = -1;
    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
#ifdef SO_NOSIGPIPE
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
        int fl = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, fl | O_NONBLOCK);
        int rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (rc != 0 && errno == EINPROGRESS) {
            struct pollfd p = {fd, POLLOUT, 0};
            int e = 0;
            socklen_t el = sizeof e;
            if (poll(&p, 1, IO_TIMEOUT_MS) == 1 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &el) == 0 && e == 0) rc = 0;
        }
        if (rc == 0) {
            fcntl(fd, F_SETFL, fl);
            struct timeval tv = {IO_TIMEOUT_MS / 1000, 0};
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
            break;
        }
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

static int send_all(int fd, const char *p, size_t n, int64_t deadline) {
    while (n > 0) {
        if (mono_ms() > deadline) return 0;
        ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
        if (w < 0) {
            if (errno == EINTR) continue;
            return 0;
        }
        p += w;
        n -= (size_t)w;
    }
    return 1;
}

/* One POST; the whole exchange is capped at about 2 * IO_TIMEOUT_MS. Any failure just drops the batch. */
static void post_batch(const export_cfg *c, const char *body, size_t blen) {
    int fd = connect_to(c);
    if (fd < 0) return;
    int64_t deadline = mono_ms() + 2 * IO_TIMEOUT_MS;
    char head[MAX_HEADERS_LEN + 1024];
    int hn = snprintf(head, sizeof head,
                      "POST %s HTTP/1.1\r\nHost: %s%s%s\r\nContent-Type: application/json\r\n"
                      "Content-Length: %zu\r\nConnection: close\r\n%s\r\n",
                      c->path, c->host, strcmp(c->port, "80") ? ":" : "", strcmp(c->port, "80") ? c->port : "", blen,
                      c->headers);
    if (hn > 0 && (size_t)hn < sizeof head && send_all(fd, head, (size_t)hn, deadline) &&
        send_all(fd, body, blen, deadline)) {
        char tmp[1024];
        while (mono_ms() < deadline) {
            ssize_t r = recv(fd, tmp, sizeof tmp, 0);
            if (r > 0) continue;
            if (r < 0 && errno == EINTR) continue;
            break;
        }
    }
    close(fd);
}

static void send_spans(const export_cfg *c, const span_rec *recs, int n) {
    jbuf b = {0};
    jstr(&b, "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":");
    jquote(&b, c->service, strlen(c->service));
    jstr(&b, "}}]},\"scopeSpans\":[{\"scope\":{\"name\":\"goose-web\"},\"spans\":[");
    for (int i = 0; i < n; i++) {
        if (i) jput(&b, ",", 1);
        span_json(&b, &recs[i]);
    }
    jstr(&b, "]}]}]}");
    if (!b.oom) post_batch(c, b.p, b.len);
    free(b.p);
}

typedef struct { export_cfg cfg; unsigned gen; } exp_arg;

static void *exporter_main(void *argp) {
    exp_arg *arg = argp;
    span_rec *recs = malloc(sizeof(span_rec) * BATCH_MAX);
    int64_t next_ms = mono_ms() + 1000;
    pthread_mutex_lock(&mu);
    while (recs && arg->gen == exp_gen) {
        while (!exp_stopping && ring_count < BATCH_MAX && arg->gen == exp_gen) {
            int64_t left = next_ms - mono_ms();
            if (left <= 0) break;
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            ts.tv_sec += left / 1000;
            ts.tv_nsec += (left % 1000) * 1000000L;
            if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
            pthread_cond_timedwait(&cv, &mu, &ts);
        }
        if (arg->gen != exp_gen) break;
        int n = ring_count < BATCH_MAX ? ring_count : BATCH_MAX;
        if (n == 0) {
            if (exp_stopping) break;
            next_ms = mono_ms() + 1000;
            continue;
        }
        for (int i = 0; i < n; i++) recs[i] = ring[(ring_head + i) % RING_CAP];
        ring_head = (ring_head + n) % RING_CAP;
        ring_count -= n;
        next_ms = mono_ms() + 1000;
        pthread_mutex_unlock(&mu);
        send_spans(&arg->cfg, recs, n);
        pthread_mutex_lock(&mu);
    }
    if (arg->gen == exp_gen) { exp_done = 1; pthread_cond_broadcast(&cv); }
    pthread_mutex_unlock(&mu);
    free(recs);
    free(arg);
    return NULL;
}

/* Sends what is queued, waits up to timeout_ms, stops the exporter. 1 when the ring was drained and the thread
   joined, 0 when it timed out (the thread is then abandoned and exits on its own). */
int32_t gweb_otel_flush(int32_t timeout_ms) {
    pthread_mutex_lock(&mu);
    if (!exp_running) { pthread_mutex_unlock(&mu); return 1; }
    exp_stopping = 1;
    pthread_cond_broadcast(&cv);
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += timeout_ms / 1000;
    ts.tv_nsec += (timeout_ms % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
    int rc = 0;
    while (!exp_done && rc == 0) rc = pthread_cond_timedwait(&cv, &mu, &ts);
    int done = exp_done;
    if (!done) exp_gen++; /* the old thread notices and leaves */
    exp_running = 0;
    atomic_store(&otel_on_v, 0);
    pthread_t th = exp_thread;
    pthread_mutex_unlock(&mu);
    if (done) pthread_join(th, NULL);
    else pthread_detach(th);
    return done;
}

/* ---- configuration from the environment ---- */

static int url_decode(const char *s, size_t n, char *out, size_t max) {
    size_t o = 0;
    for (size_t i = 0; i < n; i++) {
        int c = (uint8_t)s[i];
        if (c == '%' && i + 2 < n && hex_val(s[i + 1]) >= 0 && hex_val(s[i + 2]) >= 0) {
            c = hex_val(s[i + 1]) << 4 | hex_val(s[i + 2]);
            i += 2;
        }
        if (c == '\r' || c == '\n' || c == 0) return 0;
        if (o + 1 >= max) return 0;
        out[o++] = (char)c;
    }
    out[o] = 0;
    return 1;
}

static void trim(const char **s, size_t *n) {
    while (*n && (**s == ' ' || **s == '\t')) { (*s)++; (*n)--; }
    while (*n && ((*s)[*n - 1] == ' ' || (*s)[*n - 1] == '\t')) (*n)--;
}

/* "k=v,k2=v2" to "k: v\r\nk2: v2\r\n"; bad pairs are skipped. */
static void parse_headers(const char *env, char *out, size_t max) {
    out[0] = 0;
    size_t used = 0;
    while (env && *env) {
        const char *comma = strchr(env, ',');
        size_t n = comma ? (size_t)(comma - env) : strlen(env);
        const char *eq = memchr(env, '=', n);
        if (eq) {
            const char *k = env;
            size_t kn = (size_t)(eq - env);
            const char *v = eq + 1;
            size_t vn = n - kn - 1;
            trim(&k, &kn);
            trim(&v, &vn);
            char key[128], val[1024];
            int ok = kn > 0 && kn < sizeof key;
            for (size_t i = 0; ok && i < kn; i++) {
                uint8_t c = (uint8_t)k[i];
                if (c <= ' ' || c == ':' || c >= 0x7f) ok = 0;
            }
            if (ok) { memcpy(key, k, kn); key[kn] = 0; }
            if (ok && url_decode(v, vn, val, sizeof val)) {
                int w = snprintf(out + used, max - used, "%s: %s\r\n", key, val);
                if (w > 0 && used + (size_t)w < max) used += (size_t)w;
                else out[used] = 0;
            }
        }
        env = comma ? comma + 1 : env + n;
    }
}

/* http://host[:port][/path] */
static int parse_url(const char *url, export_cfg *c) {
    if (strncmp(url, "http://", 7) != 0) return 0;
    const char *p = url + 7;
    const char *end = p + strcspn(p, "/?#");
    const char *hs, *he;
    const char *colon = NULL;
    if (*p == '[') {
        const char *rb = memchr(p, ']', (size_t)(end - p));
        if (!rb) return 0;
        hs = p + 1;
        he = rb;
        if (rb + 1 < end && rb[1] == ':') colon = rb + 1;
    } else {
        hs = p;
        const char *cl = memchr(p, ':', (size_t)(end - p));
        he = cl ? cl : end;
        colon = cl;
    }
    if (he - hs <= 0 || (size_t)(he - hs) >= sizeof c->host) return 0;
    memcpy(c->host, hs, (size_t)(he - hs));
    c->host[he - hs] = 0;
    if (colon) {
        size_t pn = (size_t)(end - colon - 1);
        if (pn == 0 || pn >= sizeof c->port) return 0;
        memcpy(c->port, colon + 1, pn);
        c->port[pn] = 0;
        for (size_t i = 0; i < pn; i++) if (c->port[i] < '0' || c->port[i] > '9') return 0;
    } else {
        strcpy(c->port, "80");
    }
    const char *path = *end == '/' ? end : "/";
    if (strlen(path) >= sizeof c->path) return 0;
    strcpy(c->path, path);
    if (*end != '/' && *end) return 0; /* a bare ?query or #fragment is not supported */
    return 1;
}

static void warn(const char *msg, const char *url) {
    fprintf(stderr, "goose-web: tracing disabled: %s%s%s\n", msg, url ? ": " : "", url ? url : "");
}

/* 0 off, 1 on, 2 refused (not plain http). */
int32_t gweb_otel_start_from_env(void) {
    const char *traces = getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT");
    const char *base = getenv("OTEL_EXPORTER_OTLP_ENDPOINT");
    char url[1024];
    if (traces && *traces) {
        snprintf(url, sizeof url, "%s", traces);
    } else if (base && *base) {
        size_t n = strlen(base);
        while (n > 0 && base[n - 1] == '/') n--;
        snprintf(url, sizeof url, "%.*s/v1/traces", (int)n, base);
    } else {
        return 0;
    }

    const char *sampler = getenv("OTEL_TRACES_SAMPLER");
    const char *arg = getenv("OTEL_TRACES_SAMPLER_ARG");
    double ratio = 1.0;
    int parent = 1;
    if (arg && *arg) {
        char *e;
        double v = strtod(arg, &e);
        if (e != arg && v >= 0 && v <= 1) ratio = v;
    }
    if (sampler && *sampler) {
        if (!strcmp(sampler, "always_off")) return 0;
        if (!strcmp(sampler, "always_on")) { ratio = 1.0; parent = 0; }
        else if (!strcmp(sampler, "traceidratio")) parent = 0;
        else if (!strcmp(sampler, "parentbased_always_on")) ratio = 1.0;
        else if (!strcmp(sampler, "parentbased_always_off")) ratio = 0.0;
    }

    export_cfg *c = calloc(1, sizeof *c);
    exp_arg *a = calloc(1, sizeof *a);
    if (!c || !a) { free(c); free(a); return 0; }
    if (!strncmp(url, "https://", 8)) {
        warn("https endpoints are not supported (no TLS client); use a local collector", url);
        free(c); free(a);
        return 2;
    }
    if (!parse_url(url, c)) {
        warn("unusable endpoint", url);
        free(c); free(a);
        return 2;
    }
    const char *svc = getenv("OTEL_SERVICE_NAME");
    snprintf(c->service, sizeof c->service, "%s", svc && *svc ? svc : "goose-web");
    parse_headers(getenv("OTEL_EXPORTER_OTLP_HEADERS"), c->headers, sizeof c->headers);

    pthread_mutex_lock(&mu);
    if (exp_running) {
        pthread_mutex_unlock(&mu);
        free(c); free(a);
        return 1;
    }
    a->cfg = *c;
    free(c);
    a->gen = ++exp_gen;
    exp_stopping = 0;
    exp_done = 0;
    if (pthread_create(&exp_thread, NULL, exporter_main, a) != 0) {
        pthread_mutex_unlock(&mu);
        free(a);
        warn("cannot start the exporter thread", NULL);
        return 0;
    }
    exp_running = 1;
    atomic_store(&otel_ratio_v, ratio);
    atomic_store(&otel_parent_v, parent);
    atomic_store(&otel_on_v, 1);
    pthread_mutex_unlock(&mu);
    return 1;
}
