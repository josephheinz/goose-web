/* Tests for src/inflight.c against a stub goose.h. */
#include "goose.h"
#include <stdio.h>
#include <unistd.h>
#include <sys/socket.h>

typedef struct { const uint8_t *data; int64_t len; } bytes;
void gweb_inflight_init(int64_t);
void gweb_inflight_set_loop(int64_t, uint64_t);
uint64_t gweb_inflight_loop(int64_t);
void gweb_inflight_begin(int64_t, int32_t, bytes);
void gweb_inflight_set_route(int64_t, int64_t);
int64_t gweb_inflight_get_route(int64_t);
void gweb_inflight_set_phase(int64_t, int64_t);
int64_t gweb_inflight_get_phase(int64_t);
int32_t gweb_inflight_fd(int64_t);
void gweb_inflight_end(int64_t);
int32_t gweb_inflight_pending(int64_t);
void gweb_inflight_set_why(int64_t, bytes);
int64_t gweb_inflight_take_head(int64_t, gs_rref);
int64_t gweb_inflight_take_why(int64_t, gs_rref);
void gweb_inflight_plain_500(int32_t);

static int failures, checks;
#define CHECK(c) do { checks++; if (!(c)) { failures++; printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

static bytes B(const char *s) { bytes b = { (const uint8_t *)s, (int64_t)strlen(s) }; return b; }

static int head_is(int64_t slot, const char *want, size_t n) {
    gs_buf b = {0};
    int64_t got = gweb_inflight_take_head(slot, &b);
    int ok = got == (int64_t)n && b.len == n && (n == 0 || memcmp(b.data, want, n) == 0);
    free(b.data);
    return ok;
}

int main(void) {
    /* no table: every call is harmless */
    gweb_inflight_begin(0, 5, B("GET / HTTP/1.1\r\n\r\n"));
    CHECK(gweb_inflight_pending(0) == 0);
    CHECK(gweb_inflight_loop(0) == 0);
    CHECK(gweb_inflight_get_route(0) == -1);

    gweb_inflight_init(3);
    for (int i = 0; i < 3; i++) { CHECK(gweb_inflight_pending(i) == 0); CHECK(gweb_inflight_fd(i) == -1); CHECK(gweb_inflight_get_route(i) == -1); }
    CHECK(gweb_inflight_pending(3) == 0 && gweb_inflight_pending(-1) == 0);       /* out of range */

    gweb_inflight_set_loop(1, 0xabcdef0123ULL);
    CHECK(gweb_inflight_loop(1) == 0xabcdef0123ULL && gweb_inflight_loop(0) == 0);

    /* the head is the bytes before CRLF CRLF; the body is not copied */
    const char *req = "POST /a?b=1 HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello";
    gweb_inflight_begin(1, 42, B(req));
    CHECK(gweb_inflight_pending(1) == 1 && gweb_inflight_fd(1) == 42);
    const char *want = "POST /a?b=1 HTTP/1.1\r\nHost: x\r\nContent-Length: 5";
    CHECK(head_is(1, want, strlen(want)));
    CHECK(gweb_inflight_get_route(1) == -1 && gweb_inflight_get_phase(1) == 0);
    CHECK(gweb_inflight_loop(1) == 0xabcdef0123ULL);                               /* begin keeps the loop */
    CHECK(gweb_inflight_pending(0) == 0 && gweb_inflight_pending(2) == 0);         /* other slots untouched */

    gweb_inflight_set_route(1, 7);
    gweb_inflight_set_phase(1, 1);
    CHECK(gweb_inflight_get_route(1) == 7 && gweb_inflight_get_phase(1) == 1);

    /* a head and its re-parse text: appending CRLF CRLF gives back a parseable head */
    {
        gs_buf b = {0};
        gweb_inflight_take_head(1, &b);
        gs_bld_append(&b, "\r\n\r\n", 4);
        CHECK(memcmp(b.data, "POST ", 5) == 0 && memcmp(b.data + b.len - 4, "\r\n\r\n", 4) == 0);
        free(b.data);
    }

    /* why */
    {
        gs_buf b = {0};
        CHECK(gweb_inflight_take_why(1, &b) == 0);
        gweb_inflight_set_why(1, B("index out of bounds at p3.goose:12"));
        CHECK(gweb_inflight_take_why(1, &b) == 34 && memcmp(b.data, "index out of bounds", 19) == 0);
        free(b.data);
        char *big = malloc(10000);
        memset(big, 'w', 10000);
        bytes bb = { (const uint8_t *)big, 10000 };
        gweb_inflight_set_why(1, bb);
        gs_buf c = {0};
        CHECK(gweb_inflight_take_why(1, &c) == 4096);
        free(c.data);
        free(big);
    }

    /* end clears the request but keeps the loop; begin clears the old why */
    gweb_inflight_end(1);
    CHECK(gweb_inflight_pending(1) == 0 && gweb_inflight_fd(1) == -1 && gweb_inflight_get_route(1) == -1);
    CHECK(head_is(1, "", 0));
    CHECK(gweb_inflight_loop(1) == 0xabcdef0123ULL);
    gweb_inflight_begin(1, 9, B("GET / HTTP/1.1\r\n\r\n"));
    {
        gs_buf b = {0};
        CHECK(gweb_inflight_take_why(1, &b) == 0);
        CHECK(head_is(1, "GET / HTTP/1.1", 14));
        free(b.data);
    }
    gweb_inflight_end(1);

    /* a head over 8 KiB is cut at a line end */
    {
        size_t cap = 20000;
        char *r = malloc(cap);
        size_t n = 0;
        n += (size_t)snprintf(r + n, cap - n, "GET / HTTP/1.1\r\n");
        int lines = 0;
        while (n < 12000) { n += (size_t)snprintf(r + n, cap - n, "X-Pad-%d: %0100d\r\n", lines++, 7); }
        n += (size_t)snprintf(r + n, cap - n, "\r\nbody");
        bytes rb = { (const uint8_t *)r, (int64_t)n };
        gweb_inflight_begin(2, 11, rb);
        gs_buf b = {0};
        int64_t got = gweb_inflight_take_head(2, &b);
        CHECK(got > 8000 && got <= 8192);
        /* it ends where the next header line would start: followed by CRLF in the original, and not mid-line */
        CHECK(memcmp(r, b.data, (size_t)got) == 0 && r[got] == '\r' && r[got + 1] == '\n');
        free(b.data);
        free(r);
        gweb_inflight_end(2);
    }

    /* a head of exactly the window and no body; no blank line at all (a half-read request) */
    gweb_inflight_begin(0, 3, B("GET / HTTP/1.1\r\nHost: y"));
    CHECK(head_is(0, "GET / HTTP/1.1", 14));
    gweb_inflight_end(0);
    gweb_inflight_begin(0, 3, B("GET /nothing-with-no-line-end"));
    CHECK(head_is(0, "", 0));
    gweb_inflight_end(0);

    /* plain_500 writes a complete, correctly sized response */
    {
        int sv[2];
        CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
        gweb_inflight_plain_500(sv[0]);
        close(sv[0]);
        char buf[512];
        size_t n = 0;
        ssize_t r;
        while ((r = read(sv[1], buf + n, sizeof buf - 1 - n)) > 0) n += (size_t)r;
        buf[n] = 0;
        close(sv[1]);
        CHECK(strncmp(buf, "HTTP/1.1 500 Internal Server Error\r\n", 36) == 0);
        CHECK(strstr(buf, "Connection: close\r\n") != NULL);
        const char *body = strstr(buf, "\r\n\r\n");
        CHECK(body != NULL && strcmp(body + 4, "500 Internal Server Error\n") == 0);
        CHECK(strstr(buf, "Content-Length: 26\r\n") != NULL && strlen(body + 4) == 26);
        gweb_inflight_plain_500(-1);                                                /* harmless */
    }

    /* re-init resets */
    gweb_inflight_init(2);
    CHECK(gweb_inflight_loop(1) == 0 && gweb_inflight_pending(2) == 0);

    printf("inflight_c_test: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
