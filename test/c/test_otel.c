#define _GNU_SOURCE
#include "goose.h"
#include "ops.h"
#include "check.h"

#include <dirent.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>

extern char **environ;

#define S(lit) ((gweb_bytes){(const uint8_t *)(lit), (int64_t)strlen(lit)})
#define E gweb_bytes_empty
static const gweb_bytes gweb_bytes_empty = {NULL, 0};

static const char *TRACE = "4bf92f3577b34da6a3ce929d0e0e4736";
static const char *SPAN = "00f067aa0ba902b7";
static const char *PARENT = "a2fb4a1d1a96d312";

static int64_t ms_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int parse(const char *h, char *trace, char *parent, int *sampled) {
    gs_buf t = {0}, p = {0};
    int32_t s = -1;
    int ok = gweb_trace_parse(S(h), &t, &p, &s);
    if (ok) {
        memcpy(trace, t.data, 32); trace[32] = 0;
        memcpy(parent, p.data, 16); parent[16] = 0;
        *sampled = s;
    } else CHECK(t.len == 0 && p.len == 0);
    free(t.data); free(p.data);
    return ok;
}

static void test_parse(void) {
    char t[33], p[17];
    int s;
    CHECK(parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", t, p, &s));
    CHECK(!strcmp(t, TRACE) && !strcmp(p, SPAN) && s == 1);
    CHECK(parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00", t, p, &s) && s == 0);
    CHECK(parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-03", t, p, &s) && s == 1);
    CHECK(parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-02", t, p, &s) && s == 0);
    CHECK(!parse("01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", t, p, &s));
    CHECK(!parse("ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", t, p, &s));
    CHECK(!parse("00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01", t, p, &s));
    CHECK(!parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00F067AA0BA902B7-01", t, p, &s));
    CHECK(!parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-0A", t, p, &s));
    CHECK(!parse("00-00000000000000000000000000000000-00f067aa0ba902b7-01", t, p, &s));
    CHECK(!parse("00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01", t, p, &s));
    CHECK(!parse("00-4bf92f3577b34da6a3ce929d0e0e473-00f067aa0ba902b7-01", t, p, &s));
    CHECK(!parse("00-4bf92f3577b34da6a3ce929d0e0e47366-00f067aa0ba902b7-01", t, p, &s));
    CHECK(!parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b-01", t, p, &s));
    CHECK(!parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-1", t, p, &s));
    CHECK(!parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-011", t, p, &s));
    CHECK(!parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7", t, p, &s));
    CHECK(!parse("00_4bf92f3577b34da6a3ce929d0e0e4736_00f067aa0ba902b7_01", t, p, &s));
    CHECK(!parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01 ", t, p, &s));
    CHECK(!parse("00-4bf92f3577b34da6a3ce929d0e0e473g-00f067aa0ba902b7-01", t, p, &s));
    CHECK(!parse("", t, p, &s));

    gs_buf b = {0};
    gweb_traceparent(&b, S("4bf92f3577b34da6a3ce929d0e0e4736"), S("00f067aa0ba902b7"), 1);
    CHECK(b.len == 55 && !strcmp(b.data, "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"));
    free(b.data);
    gs_buf c = {0};
    gweb_traceparent(&c, S("4bf92f3577b34da6a3ce929d0e0e4736"), S("00f067aa0ba902b7"), 0);
    CHECK(c.len == 55 && !strcmp(c.data + 52, "-00"));
    char t2[33], p2[17];
    CHECK(parse(c.data, t2, p2, &s) && s == 0 && !strcmp(t2, TRACE));
    free(c.data);
}

static void test_sampling(void) {
    /* lower 8 bytes (last 16 hex chars) decide: 0x7fff... is below 0.5 * 2^64, 0x8000... is not */
    gweb_bytes low = S("00000000000000007fffffffffffffff"), high = S("00000000000000008000000000000000");
    CHECK(gweb_trace_start(-1, low, 0.5) == 1);
    CHECK(gweb_trace_start(-1, high, 0.5) == 0);
    CHECK(gweb_trace_start(-1, low, 0.0) == 0 && gweb_trace_start(-1, high, 0.0) == 0);
    CHECK(gweb_trace_start(-1, low, 1.0) == 1 && gweb_trace_start(-1, high, 1.0) == 1);
    CHECK(gweb_trace_start(-1, S("ffffffffffffffffffffffffffffffff"), 1.0) == 1);
    CHECK(gweb_trace_start(-1, S("00000000000000000000000000000000"), 0.0) == 0);
    CHECK(gweb_trace_start(-1, S("0000000000000000ffffffffffffffff"), 0.999) == 0);
    CHECK(gweb_trace_start(-1, S("ffffffffffffffff0000000000000000"), 0.001) == 1); /* only the lower half counts */
    /* the parent flag wins over the ratio */
    CHECK(gweb_trace_start(1, high, 0.0) == 1);
    CHECK(gweb_trace_start(0, low, 1.0) == 0);
    /* roughly the ratio over random ids */
    int hits = 0;
    for (int i = 0; i < 4000; i++) {
        gs_buf b = {0};
        gweb_rand_hex(&b, 16);
        hits += gweb_trace_start(-1, (gweb_bytes){(const uint8_t *)b.data, b.len}, 0.25);
        free(b.data);
    }
    CHECK(hits > 800 && hits < 1200);
}

/* ---- fake collector ---- */

typedef struct { pid_t pid; int port; char dir[512]; } collector;

static const char *outdir(void) { const char *d = getenv("GWEB_TEST_OUT"); return d ? d : "/tmp"; }

static int collector_start(collector *c, const char *name, int hang) {
    char portfile[600], script[] = "test/c/fake_collector.py";
    snprintf(c->dir, sizeof c->dir, "%s/%s", outdir(), name);
    snprintf(portfile, sizeof portfile, "%s.port", c->dir);
    unlink(portfile);
    char *argv[] = {"python3", script, "--dir", c->dir, "--port-file", portfile, hang ? "--hang" : NULL, NULL};
    if (posix_spawnp(&c->pid, "python3", NULL, NULL, argv, environ) != 0) return 0;
    for (int i = 0; i < 200; i++) {
        FILE *f = fopen(portfile, "r");
        if (f) {
            int n = fscanf(f, "%d", &c->port);
            fclose(f);
            if (n == 1 && c->port > 0) return 1;
        }
        usleep(50000);
    }
    return 0;
}

static void collector_stop(collector *c) {
    if (c->pid > 0) { kill(c->pid, SIGTERM); waitpid(c->pid, NULL, 0); }
    c->pid = 0;
}

static int collector_count(collector *c) {
    int n = 0;
    DIR *d = opendir(c->dir);
    if (!d) return 0;
    struct dirent *e;
    while ((e = readdir(d))) if (e->d_name[0] != '.' && strstr(e->d_name, ".json")) n++;
    closedir(d);
    return n;
}

static int wait_count(collector *c, int want, int ms) {
    int64_t end = ms_now() + ms;
    while (ms_now() < end) {
        if (collector_count(c) >= want) return 1;
        usleep(20000);
    }
    return collector_count(c) >= want;
}

static char *read_req(collector *c, int n) {
    char path[640];
    snprintf(path, sizeof path, "%s/%04d.json", c->dir, n);
    FILE *f = fopen(path, "r");
    if (!f) return NULL;
    char *buf = malloc(1 << 22);
    size_t len = fread(buf, 1, (1 << 22) - 1, f);
    buf[len] = 0;
    fclose(f);
    return buf;
}

static int check_req(collector *c, int n, const char *a1, const char *a2, const char *a3, const char *a4,
                     const char *a5, const char *a6, const char *a7, const char *a8) {
    char cmd[4096];
    const char *as[] = {a1, a2, a3, a4, a5, a6, a7, a8};
    int o = snprintf(cmd, sizeof cmd, "python3 -I test/c/otelcheck.py '%s/%04d.json'", c->dir, n);
    for (int i = 0; i < 8; i++)
        if (as[i]) o += snprintf(cmd + o, sizeof cmd - (size_t)o, " '%s'", as[i]);
    return system(cmd) == 0;
}

static int total_spans(collector *c, int *max_batch) {
    int total = 0, n = collector_count(c);
    *max_batch = 0;
    for (int i = 1; i <= n; i++) {
        char *r = read_req(c, i);
        if (!r) continue;
        int k = 0;
        for (char *p = r; (p = strstr(p, "spanId")); p += 6) k++;
        total += k;
        if (k > *max_batch) *max_batch = k;
        free(r);
    }
    return total;
}

static void clear_env(void) {
    unsetenv("OTEL_EXPORTER_OTLP_ENDPOINT");
    unsetenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT");
    unsetenv("OTEL_SERVICE_NAME");
    unsetenv("OTEL_TRACES_SAMPLER");
    unsetenv("OTEL_TRACES_SAMPLER_ARG");
    unsetenv("OTEL_EXPORTER_OTLP_HEADERS");
}

static void set_endpoint(collector *c, const char *suffix, int traces_var) {
    char url[256];
    snprintf(url, sizeof url, "http://127.0.0.1:%d%s", c->port, suffix);
    setenv(traces_var ? "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT" : "OTEL_EXPORTER_OTLP_ENDPOINT", url, 1);
}

static int push_simple(int i) {
    char sid[17];
    snprintf(sid, sizeof sid, "%016x", i + 1);
    return gweb_span_push(S("4bf92f3577b34da6a3ce929d0e0e4736"), (gweb_bytes){(const uint8_t *)sid, 16}, E, S("s"), 1,
                          1000, 2000, 0, E, E, E, 0, E, E, 0);
}

static void test_ring_full(void) {
    clear_env();
    int64_t d0 = gweb_spans_dropped();
    int stored = 0;
    for (int i = 0; i < 8192; i++) stored += push_simple(i);
    CHECK(stored == 8192 && gweb_spans_dropped() == d0);
    CHECK(push_simple(9000) == 0 && gweb_spans_dropped() == d0 + 1);
    CHECK(push_simple(9001) == 0 && gweb_spans_dropped() == d0 + 2);
    CHECK(gweb_span_push(S("zz"), S(SPAN), E, S("bad"), 1, 0, 0, 0, E, E, E, 0, E, E, 0) == 0);
    CHECK(gweb_spans_dropped() == d0 + 3);

    collector c = {0};
    CHECK(collector_start(&c, "ring", 0));
    set_endpoint(&c, "", 0);
    CHECK(gweb_otel_start_from_env() == 1);
    CHECK(gweb_otel_flush(10000) == 1);
    int maxb, total = total_spans(&c, &maxb);
    CHECK(total == 8192);
    CHECK(maxb == 512 && collector_count(&c) == 16);
    CHECK(gweb_spans_dropped() == d0 + 3);
    collector_stop(&c);
}

static void test_export(void) {
    clear_env();
    collector c = {0};
    CHECK(collector_start(&c, "export", 0));
    set_endpoint(&c, "/", 0);
    setenv("OTEL_SERVICE_NAME", "shop \"api\"", 1);
    setenv("OTEL_EXPORTER_OTLP_HEADERS", "x-api-key=abc%20d%2Cx, Authorization = Bearer t0k,broken,=nokey,bad:key=1", 1);
    CHECK(gweb_otel_start_from_env() == 1);
    CHECK(gweb_otel_on() == 1 && gweb_otel_ratio() == 1.0 && gweb_otel_parent_based() == 1);

    char longname[260];
    memset(longname, 'a', 100);
    memcpy(longname + 100, "\"\\\x01\n", 4);
    char longpath[400];
    memset(longpath, 'p', 300);
    longpath[0] = '/';
    longpath[300] = 0;
    CHECK(gweb_span_push(S(TRACE), S(SPAN), S(PARENT), S("GET /users/:id"), 2, 1700000000123456789LL,
                         1700000000223456789LL, 2, S("GET"), S("/users/:id"), S("/users/42"), 500, E, E, 0) == 1);
    CHECK(gweb_span_push(S(TRACE), S("1111111111111111"), S(SPAN), S("job Welcome"), 1, 5, 6, 0, E, E, E, 0,
                         S("job.attempt"), S("2"), 1) == 1);
    CHECK(gweb_span_push(S(TRACE), S("2222222222222222"), E, (gweb_bytes){(const uint8_t *)longname, 104}, 1, 7, 8, 0,
                         S("POST"), E, (gweb_bytes){(const uint8_t *)longpath, 300}, 200, S("note"), S("hi"), 0) == 1);
    CHECK(gweb_otel_flush(5000) == 1);
    CHECK(gweb_otel_on() == 0);
    CHECK(collector_count(&c) == 1);

    CHECK(check_req(&c, 1, "path=/v1/traces", "header:content-type=application/json",
                    "header:x-api-key=abc d,x", "header:authorization=Bearer t0k", "header:connection=close",
                    "resourceSpans.0.resource.attributes.0.key=service.name",
                    "resourceSpans.0.resource.attributes.0.value.stringValue=shop \"api\"",
                    "resourceSpans.0.scopeSpans.0.scope.name=goose-web"));
    const char *sp = "resourceSpans.0.scopeSpans.0.spans.";
    char a[8][256];
    snprintf(a[0], 256, "%s0.traceId=%s", sp, TRACE);
    snprintf(a[1], 256, "%s0.spanId=%s", sp, SPAN);
    snprintf(a[2], 256, "%s0.parentSpanId=%s", sp, PARENT);
    snprintf(a[3], 256, "%s0.name=GET /users/:id", sp);
    snprintf(a[4], 256, "%s0.kind=2", sp);
    snprintf(a[5], 256, "%s0.startTimeUnixNano=1700000000123456789", sp);
    snprintf(a[6], 256, "%s0.endTimeUnixNano=1700000000223456789", sp);
    snprintf(a[7], 256, "%s0.status.code=2", sp);
    CHECK(check_req(&c, 1, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]));
    snprintf(a[0], 256, "len:%s0.attributes=4", sp);
    CHECK(check_req(&c, 1, a[0], "attr:0:http.request.method=GET", "attr:0:http.route=/users/:id",
                    "attr:0:url.path=/users/42", "attr:0:http.response.status_code=500", "len:resourceSpans=1",
                    "len:resourceSpans.0.scopeSpans.0.spans=3", NULL));
    snprintf(a[0], 256, "has:%s1.status=0", sp);
    snprintf(a[1], 256, "%s1.kind=1", sp);
    snprintf(a[2], 256, "%s1.parentSpanId=%s", sp, SPAN);
    CHECK(check_req(&c, 1, a[0], a[1], a[2], "attr:1:job.attempt=2", "has:resourceSpans.0.scopeSpans.0.spans.2.parentSpanId=0",
                    "attr:2:note=hi", NULL, NULL));
    char *r = read_req(&c, 1);
    CHECK(r != NULL);
    if (r) {
        /* a request file holds the body as a JSON string, so every backslash shows up doubled */
        CHECK(strstr(r, "\\\"intValue\\\": \\\"2\\\"") || strstr(r, "\\\"intValue\\\":\\\"2\\\""));
        CHECK(strstr(r, "\\\\\\\"\\\\\\\\\\\\u0001\\\\u000a"));
        char want[101];
        memset(want, 'a', 100);
        want[100] = 0;
        CHECK(strstr(r, want) != NULL);
        char p256[300];
        memset(p256, 'p', 255);
        p256[255] = 0;
        CHECK(strstr(r, p256) != NULL);
        memset(p256, 'p', 256);
        p256[256] = 0;
        CHECK(strstr(r, p256) == NULL);
        free(r);
    }
    collector_stop(&c);
}

static void test_truncation(void) {
    clear_env();
    collector c = {0};
    CHECK(collector_start(&c, "trunc", 0));
    set_endpoint(&c, "", 0);
    CHECK(gweb_otel_start_from_env() == 1);
    char name[400];
    memset(name, 'n', 127);
    memcpy(name + 127, "\xc3\xa9zzzz", 7); /* e-acute straddles the 128-byte cut */
    char bad[8] = "ab\xff\xfe" "cd";
    CHECK(gweb_span_push(S(TRACE), S(SPAN), E, (gweb_bytes){(const uint8_t *)name, 134}, 1, 1, 2, 0, E, E, E, 0, E, E, 0));
    CHECK(gweb_span_push(S(TRACE), S("3333333333333333"), E, (gweb_bytes){(const uint8_t *)bad, 6}, 1, 1, 2, 0, E, E, E, 0, E, E, 0));
    CHECK(gweb_otel_flush(5000) == 1);
    char want[200];
    snprintf(want, sizeof want, "resourceSpans.0.scopeSpans.0.spans.1.name=ab\xef\xbf\xbd\xef\xbf\xbd" "cd");
    char exp0[300] = "resourceSpans.0.scopeSpans.0.spans.0.name=";
    memset(exp0 + strlen(exp0), 'n', 127);
    exp0[strlen("resourceSpans.0.scopeSpans.0.spans.0.name=") + 127] = 0;
    CHECK(check_req(&c, 1, want, exp0, NULL, NULL, NULL, NULL, NULL, NULL));
    collector_stop(&c);
}

static void test_endpoints_and_samplers(void) {
    collector c = {0};
    CHECK(collector_start(&c, "endpoints", 0));

    clear_env();
    CHECK(gweb_otel_start_from_env() == 0 && gweb_otel_on() == 0);

    /* the traces variable is used as is and wins over the base endpoint */
    set_endpoint(&c, "/custom/t", 1);
    setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:1", 1);
    setenv("OTEL_TRACES_SAMPLER", "traceidratio", 1);
    setenv("OTEL_TRACES_SAMPLER_ARG", "0.5", 1);
    CHECK(gweb_otel_start_from_env() == 1);
    CHECK(gweb_otel_ratio() == 0.5 && gweb_otel_parent_based() == 0);
    CHECK(gweb_otel_sample(1, S("00000000000000008000000000000000")) == 0); /* parent ignored */
    CHECK(gweb_otel_sample(-1, S("00000000000000007fffffffffffffff")) == 1);
    CHECK(push_simple(1));
    CHECK(gweb_otel_flush(5000) == 1);
    CHECK(collector_count(&c) == 1 && check_req(&c, 1, "path=/custom/t", NULL, NULL, NULL, NULL, NULL, NULL, NULL));

    /* default sampler is parent-based */
    clear_env();
    set_endpoint(&c, "//", 0);
    setenv("OTEL_TRACES_SAMPLER_ARG", "0", 1);
    CHECK(gweb_otel_start_from_env() == 1);
    CHECK(gweb_otel_parent_based() == 1 && gweb_otel_ratio() == 0.0);
    CHECK(gweb_otel_sample(1, S("00000000000000008000000000000000")) == 1);
    CHECK(gweb_otel_sample(0, S("00000000000000000000000000000001")) == 0);
    CHECK(gweb_otel_sample(-1, S("00000000000000000000000000000001")) == 0);
    CHECK(push_simple(2));
    CHECK(gweb_otel_flush(5000) == 1);
    CHECK(collector_count(&c) == 2);
    char host[64];
    snprintf(host, sizeof host, "header:host=127.0.0.1:%d", c.port);
    CHECK(check_req(&c, 2, "path=/v1/traces", host, NULL, NULL, NULL, NULL, NULL, NULL));

    /* always_on, bad ratio argument falls back to 1 */
    clear_env();
    set_endpoint(&c, "", 0);
    setenv("OTEL_TRACES_SAMPLER", "always_on", 1);
    setenv("OTEL_TRACES_SAMPLER_ARG", "0.1", 1);
    CHECK(gweb_otel_start_from_env() == 1);
    CHECK(gweb_otel_ratio() == 1.0 && gweb_otel_sample(-1, S("0000000000000000ffffffffffffffff")) == 1);
    CHECK(gweb_otel_start_from_env() == 1); /* already running */
    CHECK(gweb_otel_flush(5000) == 1);
    CHECK(gweb_otel_sample(1, S(TRACE)) == 0); /* off after flush */

    /* always_off: nothing starts */
    clear_env();
    set_endpoint(&c, "", 0);
    setenv("OTEL_TRACES_SAMPLER", "always_off", 1);
    CHECK(gweb_otel_start_from_env() == 0 && gweb_otel_on() == 0);

    /* https is refused with a warning, and nothing runs */
    clear_env();
    setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "https://collector.example:4318", 1);
    CHECK(gweb_otel_start_from_env() == 2 && gweb_otel_on() == 0);
    clear_env();
    setenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "ftp://x/y", 1);
    CHECK(gweb_otel_start_from_env() == 2);

    CHECK(gweb_otel_flush(1000) == 1); /* nothing running */
    collector_stop(&c);
}

static void test_timer_flush(void) {
    clear_env();
    collector c = {0};
    CHECK(collector_start(&c, "timer", 0));
    set_endpoint(&c, "", 0);
    CHECK(gweb_otel_start_from_env() == 1);
    CHECK(push_simple(1));
    CHECK(collector_count(&c) == 0);
    CHECK(wait_count(&c, 1, 3000)); /* the one-second timer, no flush */
    CHECK(push_simple(2));
    CHECK(push_simple(3));
    CHECK(gweb_otel_flush(5000) == 1);
    int maxb;
    CHECK(total_spans(&c, &maxb) == 3 && collector_count(&c) == 2);
    collector_stop(&c);
}

static void test_hang(void) {
    clear_env();
    collector c = {0};
    CHECK(collector_start(&c, "hang", 1));
    set_endpoint(&c, "", 0);
    CHECK(gweb_otel_start_from_env() == 1);
    CHECK(push_simple(1));
    int64_t t0 = ms_now();
    CHECK(gweb_otel_flush(10000) == 1);
    int64_t el = ms_now() - t0;
    CHECK(el >= 1500 && el < 4500);
    CHECK(collector_count(&c) == 0);
    collector_stop(&c);

    /* the dropped batch is gone: a healthy collector next sees nothing */
    collector ok = {0};
    CHECK(collector_start(&ok, "hang_after", 0));
    set_endpoint(&ok, "", 0);
    CHECK(gweb_otel_start_from_env() == 1);
    CHECK(gweb_otel_flush(5000) == 1);
    CHECK(collector_count(&ok) == 0);
    collector_stop(&ok);

    /* a flush timeout shorter than the stall returns 0 and a later start still works */
    CHECK(collector_start(&c, "hang2", 1));
    set_endpoint(&c, "", 0);
    CHECK(gweb_otel_start_from_env() == 1);
    CHECK(push_simple(1));
    t0 = ms_now();
    CHECK(gweb_otel_flush(300) == 0);
    CHECK(ms_now() - t0 < 1500);
    CHECK(collector_start(&ok, "hang_after2", 0));
    set_endpoint(&ok, "", 0);
    CHECK(gweb_otel_start_from_env() == 1);
    CHECK(push_simple(2));
    CHECK(gweb_otel_flush(5000) == 1);
    CHECK(collector_count(&ok) == 1);
    collector_stop(&ok);
    collector_stop(&c);
}

/* A collector that closes without reading must not kill the process with SIGPIPE, nor wedge it. */
static void *closer(void *arg) {
    int ls = *(int *)arg;
    for (int i = 0; i < 3; i++) {
        int fd = accept(ls, NULL, NULL);
        if (fd < 0) break;
        close(fd);
    }
    return NULL;
}

static void test_closed_by_peer(void) {
    clear_env();
    int ls = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sa = {0};
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    CHECK(bind(ls, (struct sockaddr *)&sa, sizeof sa) == 0 && listen(ls, 8) == 0);
    socklen_t sl = sizeof sa;
    getsockname(ls, (struct sockaddr *)&sa, &sl);
    char url[128];
    snprintf(url, sizeof url, "http://127.0.0.1:%d", ntohs(sa.sin_port));
    setenv("OTEL_EXPORTER_OTLP_ENDPOINT", url, 1);
    pthread_t th;
    pthread_create(&th, NULL, closer, &ls);
    CHECK(gweb_otel_start_from_env() == 1);
    for (int i = 0; i < 1500; i++) push_simple(i);
    int64_t t0 = ms_now();
    CHECK(gweb_otel_flush(8000) == 1);
    CHECK(ms_now() - t0 < 6000);
    shutdown(ls, SHUT_RDWR);
    close(ls);
    pthread_join(th, NULL);

    /* nothing listening at all: connection refused, batch dropped */
    setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:1", 1);
    CHECK(gweb_otel_start_from_env() == 1);
    CHECK(push_simple(1));
    CHECK(gweb_otel_flush(5000) == 1);
}

static void test_clock(void) {
    int64_t n = gweb_unix_ns(), t = (int64_t)time(NULL) * 1000000000LL;
    CHECK(n > t - 5000000000LL && n < t + 5000000000LL);
    CHECK(gweb_unix_ns() >= n);
}

int main(void) {
    signal(SIGPIPE, SIG_DFL);
    test_parse();
    test_sampling();
    test_clock();
    test_ring_full();
    test_export();
    test_truncation();
    test_endpoints_and_samplers();
    test_timer_flush();
    test_hang();
    test_closed_by_peer();
    return done();
}
