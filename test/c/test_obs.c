#ifndef _GNU_SOURCE
#define _GNU_SOURCE   /* usleep under -std=c11 on Linux */
#endif
#include "goose.h"
#include "ops.h"
#include "check.h"

#include <ctype.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define S(lit) ((gweb_bytes){(const uint8_t *)(lit), (int64_t)strlen(lit)})

/* strong definitions replace the weak stubs in obs.c */
int64_t gweb_jobs_stat(int32_t which) { return 100 + which; }
int64_t gweb_spans_dropped(void) { return 7; }

static char *render(const char *version) {
    gs_buf b = {0};
    gweb_metrics_render(&b, S(version));
    if (!b.data) { b.data = malloc(1); b.data[0] = 0; }
    return b.data;
}

static int has(const char *text, const char *needle) { return strstr(text, needle) != NULL; }

static void test_basics(void) {
    gs_buf b = {0};
    gweb_rfc3339(&b);
    CHECK(b.len == 24);
    const char *p = "dddd-dd-ddTdd:dd:dd.dddZ";
    int shape = b.len == 24;
    for (int i = 0; shape && i < 24; i++) shape = p[i] == 'd' ? isdigit((unsigned char)b.data[i]) != 0 : b.data[i] == p[i];
    CHECK(shape);
    CHECK(memcmp(b.data, "20", 2) == 0);

    int64_t t0 = gweb_now_us();
    usleep(2000);
    int64_t t1 = gweb_now_us();
    CHECK(t1 - t0 >= 2000 && t1 - t0 < 1000000);

    gweb_log_config(2, 1);
    CHECK(gweb_log_level() == 2 && gweb_log_json() == 1);
    gweb_log_config(0, 0);
    CHECK(gweb_log_level() == 0 && gweb_log_json() == 0);
}

static void test_rand(void) {
    int sizes[] = {1, 2, 8, 9, 16, 17};
    for (unsigned k = 0; k < sizeof sizes / sizeof *sizes; k++) {
        gs_buf b = {0};
        gweb_rand_hex(&b, sizes[k]);
        int ok = b.len == 2 * sizes[k];
        int zero = 1;
        for (int64_t i = 0; ok && i < b.len; i++) {
            ok = (b.data[i] >= '0' && b.data[i] <= '9') || (b.data[i] >= 'a' && b.data[i] <= 'f');
            if (b.data[i] != '0') zero = 0;
        }
        CHECK(ok);
        CHECK(!zero);
    }
    gs_buf z = {0};
    gweb_rand_hex(&z, 0);
    CHECK(z.len == 0);
    /* never all zeros, even for 1 byte over many draws */
    int bad = 0;
    for (int i = 0; i < 20000; i++) {
        gs_buf b = {0};
        gweb_rand_hex(&b, 1);
        if (memcmp(b.data, "00", 2) == 0) bad++;
        free(b.data);
    }
    CHECK(bad == 0);
}

static char thread_out[2][33];
static void *rand_thread(void *arg) {
    gs_buf b = {0};
    gweb_rand_hex(&b, 16);
    memcpy(thread_out[(intptr_t)arg], b.data, 33);
    return NULL;
}

static void test_rand_threads(void) {
    pthread_t t[2];
    for (intptr_t i = 0; i < 2; i++) pthread_create(&t[i], NULL, rand_thread, (void *)i);
    for (int i = 0; i < 2; i++) pthread_join(t[i], NULL);
    CHECK(strlen(thread_out[0]) == 32 && strlen(thread_out[1]) == 32);
    CHECK(strcmp(thread_out[0], thread_out[1]) != 0);
}

typedef struct { int pipe_r; char *data; size_t len; } drain_t;
static void *drain_thread(void *arg) {
    drain_t *d = arg;
    char buf[4096];
    ssize_t n;
    while ((n = read(d->pipe_r, buf, sizeof buf)) > 0) {
        d->data = realloc(d->data, d->len + (size_t)n);
        memcpy(d->data + d->len, buf, (size_t)n);
        d->len += (size_t)n;
    }
    return NULL;
}

static void test_log_line(void) {
    int saved = dup(1), fds[2];
    CHECK(pipe(fds) == 0);
    drain_t d = {fds[0], NULL, 0};
    pthread_t th;
    pthread_create(&th, NULL, drain_thread, &d);
    dup2(fds[1], 1);
    gweb_log_line(S("hello"));
    gweb_log_line(S("already\n"));
    size_t big = 300000;
    char *line = malloc(big);
    memset(line, 'x', big);
    gweb_log_line((gweb_bytes){(const uint8_t *)line, (int64_t)big});
    dup2(saved, 1);
    close(saved);
    close(fds[1]);
    pthread_join(th, NULL);
    close(fds[0]);
    CHECK(d.len == 6 + 8 + big + 1);
    CHECK(d.len > 14 && memcmp(d.data, "hello\nalready\n", 14) == 0);
    CHECK(d.len == 6 + 8 + big + 1 && d.data[d.len - 1] == '\n' && d.data[d.len - 2] == 'x');
    free(line);
    free(d.data);
}

static void test_metrics_off(void) {
    CHECK(!gweb_metrics_on());
    gweb_metrics_request(0, 0, 0, 200, 10);
    gweb_metrics_conn(0, 3);
    gweb_metric_count(S("early"), 1);
    char *t = render("0");
    CHECK(has(t, "gweb_jobs_queued 100\n"));
    CHECK(!has(t, "early"));
    CHECK(!has(t, "route="));
    free(t);
}

static void test_histogram(void) {
    gweb_metrics_init(2, S("/a\n/b"));
    CHECK(gweb_metrics_on());
    int64_t d[] = {0, 500, 501, 1000, 2500, 5000, 10000, 25000, 50000, 100000, 250000, 500000, 1000000, 2500000, 2500001};
    for (unsigned i = 0; i < sizeof d / sizeof *d; i++) gweb_metrics_request(i % 2, 0, 0, 200, d[i]);
    char *t = render("1.2.3");
    /* edge values land in their own bucket (le is inclusive) */
    CHECK(has(t, "gweb_http_request_duration_seconds_bucket{route=\"/a\",le=\"0.0005\"} 2\n"));
    CHECK(has(t, "gweb_http_request_duration_seconds_bucket{route=\"/a\",le=\"0.001\"} 4\n"));
    CHECK(has(t, "gweb_http_request_duration_seconds_bucket{route=\"/a\",le=\"0.0025\"} 5\n"));
    CHECK(has(t, "gweb_http_request_duration_seconds_bucket{route=\"/a\",le=\"0.005\"} 6\n"));
    CHECK(has(t, "gweb_http_request_duration_seconds_bucket{route=\"/a\",le=\"0.01\"} 7\n"));
    CHECK(has(t, "gweb_http_request_duration_seconds_bucket{route=\"/a\",le=\"0.025\"} 8\n"));
    CHECK(has(t, "gweb_http_request_duration_seconds_bucket{route=\"/a\",le=\"0.05\"} 9\n"));
    CHECK(has(t, "gweb_http_request_duration_seconds_bucket{route=\"/a\",le=\"0.1\"} 10\n"));
    CHECK(has(t, "gweb_http_request_duration_seconds_bucket{route=\"/a\",le=\"0.25\"} 11\n"));
    CHECK(has(t, "gweb_http_request_duration_seconds_bucket{route=\"/a\",le=\"0.5\"} 12\n"));
    CHECK(has(t, "gweb_http_request_duration_seconds_bucket{route=\"/a\",le=\"1\"} 13\n"));
    CHECK(has(t, "gweb_http_request_duration_seconds_bucket{route=\"/a\",le=\"2.5\"} 14\n"));
    CHECK(has(t, "gweb_http_request_duration_seconds_bucket{route=\"/a\",le=\"+Inf\"} 15\n"));
    CHECK(has(t, "gweb_http_request_duration_seconds_count{route=\"/a\"} 15\n"));
    /* sum in seconds: 7449 + ... computed below */
    int64_t sum = 0;
    for (unsigned i = 0; i < sizeof d / sizeof *d; i++) sum += d[i];
    char want[160];
    snprintf(want, sizeof want, "gweb_http_request_duration_seconds_sum{route=\"/a\"} %.6f\n", (double)sum / 1e6);
    CHECK(has(t, want));
    CHECK(!has(t, "route=\"/b\""));
    CHECK(has(t, "gweb_http_requests_total{route=\"/a\",method=\"GET\",code=\"2xx\"} 15\n"));
    free(t);
}

typedef struct { int worker; } wk_t;
static void *hammer(void *arg) {
    int w = ((wk_t *)arg)->worker;
    for (int i = 0; i < 10000; i++) gweb_metrics_request(w, 1, 2, 404, 100);
    gweb_metrics_conn(w, w + 1);
    return NULL;
}

static void test_workers_and_labels(void) {
    gweb_metrics_init(4, S("/x/:id\n/y"));
    pthread_t th[4];
    wk_t wk[4];
    for (int i = 0; i < 4; i++) { wk[i].worker = i; pthread_create(&th[i], NULL, hammer, &wk[i]); }
    for (int i = 0; i < 4; i++) pthread_join(th[i], NULL);
    gweb_metrics_request(0, 0, 0, 200, 1);
    gweb_metrics_request(1, 0, 1, 301, 1);
    gweb_metrics_request(2, 0, 3, 500, 1);
    gweb_metrics_request(3, 0, 4, 100, 1);
    gweb_metrics_request(0, 0, 5, 599, 1);
    gweb_metrics_request(0, 0, 6, 204, 1);
    gweb_metrics_request(0, 0, 7, 200, 1);
    gweb_metrics_request(0, 0, 99, 200, 1);   /* unknown method -> OTHER */
    gweb_metrics_request(0, -2, 0, 200, 1);
    gweb_metrics_request(0, -1, 0, 404, 1);
    gweb_metrics_request(0, 50, 0, 404, 1);   /* out of range -> "-" */
    gweb_metrics_request(9, 0, 0, 200, 1);    /* bad worker: ignored */
    char *t = render("v");
    CHECK(has(t, "gweb_http_requests_total{route=\"/y\",method=\"POST\",code=\"4xx\"} 40000\n"));
    CHECK(has(t, "gweb_http_request_duration_seconds_count{route=\"/y\"} 40000\n"));
    CHECK(has(t, "gweb_http_requests_total{route=\"/x/:id\",method=\"GET\",code=\"2xx\"} 1\n"));
    CHECK(has(t, "gweb_http_requests_total{route=\"/x/:id\",method=\"HEAD\",code=\"3xx\"} 1\n"));
    CHECK(has(t, "gweb_http_requests_total{route=\"/x/:id\",method=\"PUT\",code=\"5xx\"} 1\n"));
    CHECK(has(t, "gweb_http_requests_total{route=\"/x/:id\",method=\"PATCH\",code=\"1xx\"} 1\n"));
    CHECK(has(t, "gweb_http_requests_total{route=\"/x/:id\",method=\"DELETE\",code=\"5xx\"} 1\n"));
    CHECK(has(t, "gweb_http_requests_total{route=\"/x/:id\",method=\"OPTIONS\",code=\"2xx\"} 1\n"));
    CHECK(has(t, "gweb_http_requests_total{route=\"/x/:id\",method=\"OTHER\",code=\"2xx\"} 2\n"));
    CHECK(has(t, "gweb_http_requests_total{route=\"static\",method=\"GET\",code=\"2xx\"} 1\n"));
    CHECK(has(t, "gweb_http_requests_total{route=\"-\",method=\"GET\",code=\"4xx\"} 2\n"));
    CHECK(has(t, "gweb_http_connections_open 10\n"));
    CHECK(has(t, "gweb_jobs_queued 100\n"));
    CHECK(has(t, "gweb_jobs_running 101\n"));
    CHECK(has(t, "gweb_jobs_completed_total 102\n"));
    CHECK(has(t, "gweb_jobs_failed_total 103\n"));
    CHECK(has(t, "gweb_jobs_dropped_total 104\n"));
    CHECK(has(t, "gweb_jobs_rejected_total 105\n"));
    CHECK(has(t, "gweb_spans_dropped_total 7\n"));
    CHECK(has(t, "# TYPE gweb_http_connections_open gauge\n"));
    CHECK(has(t, "# TYPE gweb_jobs_failed_total counter\n"));
    CHECK(has(t, "# TYPE gweb_http_request_duration_seconds histogram\n"));
    CHECK(has(t, "gweb_process_start_time_seconds 1"));
    CHECK(has(t, "gweb_build_info{version=\"v\"} 1\n"));
    free(t);
}

static void write_file(const char *name, const char *text) {
    const char *dir = getenv("GWEB_TEST_OUT");
    if (!dir) return;
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "w");
    if (!f) return;
    fputs(text, f);
    fclose(f);
}

static void test_escaping(void) {
    gweb_metrics_init(1, S("/q\"uote\n/back\\slash\n/plain"));
    gweb_metrics_request(0, 0, 0, 200, 5);
    gweb_metrics_request(0, 1, 0, 200, 5);
    char *t = render("a\"b\\c\nd");
    CHECK(has(t, "gweb_http_requests_total{route=\"/q\\\"uote\",method=\"GET\",code=\"2xx\"} 1\n"));
    CHECK(has(t, "gweb_http_requests_total{route=\"/back\\\\slash\",method=\"GET\",code=\"2xx\"} 1\n"));
    CHECK(has(t, "gweb_build_info{version=\"a\\\"b\\\\c\\nd\"} 1\n"));
    write_file("escaping.prom", t);
    free(t);
}

static void test_app_metrics(void) {
    gweb_metrics_init(1, S(""));
    gweb_metric_count(S("orders_total"), 2);
    gweb_metric_count(S("orders_total"), 3);
    gweb_metric_gauge(S("queue_depth"), 4.5);
    gweb_metric_gauge(S("queue_depth"), 2.25);
    gweb_metric_count(S("queue_depth"), 1);     /* wrong kind: ignored */
    const char *bad[] = {"", "9lives", "Upper", "has-dash", "has space", "a.b", "gweb_mine",
                         "this_name_is_way_too_long_for_the_table_because_it_goes_past_63_chars_xx"};
    for (unsigned i = 0; i < sizeof bad / sizeof *bad; i++) gweb_metric_count(S(bad[i]), 1);
    gweb_metric_count(S("_ok9"), 1);
    char *t = render("v");
    CHECK(has(t, "# TYPE orders_total counter\norders_total 5\n"));
    CHECK(has(t, "# TYPE queue_depth gauge\nqueue_depth 2.25\n"));
    CHECK(has(t, "\n_ok9 1\n"));
    CHECK(!has(t, "9lives") && !has(t, "Upper") && !has(t, "has-dash") && !has(t, "gweb_mine") && !has(t, "way_too_long"));
    CHECK(has(t, "gweb_http_requests_total counter") || has(t, "# TYPE gweb_http_requests_total counter\n"));
    free(t);

    /* fill the table: 3 names exist, 253 more fit, the next is refused with one warning */
    const char *dir = getenv("GWEB_TEST_OUT");
    char errpath[1024];
    snprintf(errpath, sizeof errpath, "%s/stderr.txt", dir ? dir : ".");
    int saved = dup(2);
    int fd = open(errpath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    dup2(fd, 2);
    close(fd);
    char name[32];
    for (int i = 0; i < 253; i++) {
        snprintf(name, sizeof name, "fill_%d", i);
        gweb_metric_count(S(name), 1);
    }
    gweb_metric_count(S("over_one"), 1);
    gweb_metric_count(S("over_two"), 1);
    gweb_metric_gauge(S("over_three"), 1);
    fflush(stderr);
    dup2(saved, 2);
    close(saved);
    t = render("v");
    CHECK(has(t, "\nfill_252 1\n"));
    CHECK(!has(t, "over_one") && !has(t, "over_two") && !has(t, "over_three"));
    gweb_metric_count(S("fill_0"), 1);   /* existing names keep working at the cap */
    free(t);
    t = render("v");
    CHECK(has(t, "\nfill_0 2\n"));
    int n = 0;
    for (const char *p = t; (p = strstr(p, "\n# TYPE ")); p++) n++;
    CHECK(n >= 256);
    write_file("app.prom", t);
    free(t);

    FILE *f = fopen(errpath, "r");
    char buf[2048] = {0};
    size_t got = f ? fread(buf, 1, sizeof buf - 1, f) : 0;
    if (f) fclose(f);
    int lines = 0;
    for (size_t i = 0; i < got; i++) if (buf[i] == '\n') lines++;
    CHECK(lines == 1 && has(buf, "over_one"));
}

int main(void) {
    test_basics();
    test_rand();
    test_rand_threads();
    test_log_line();
    test_metrics_off();
    test_histogram();
    test_workers_and_labels();
    test_escaping();
    test_app_metrics();
    return done();
}
