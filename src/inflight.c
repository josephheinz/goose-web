/* The in-flight table of DESIGN-ADDENDUM-14, D12: one entry per worker slot, holding what the supervisor needs
   to answer a request whose worker aborted: the connection fd, the loop handle, the matched route, a phase flag,
   a copy of the request head and the abort text. The worker writes its own entry while it lives; the supervisor
   reads it only after thread_wait says the worker is dead, so no lock is needed. */
#include "goose.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <sys/socket.h>

typedef struct { const uint8_t *data; int64_t len; } gweb_ifbytes;

#define IF_HEAD_MAX 8192
#define IF_WHY_MAX 4096

typedef struct {
    int32_t fd;
    uint64_t loop;
    int64_t route;
    int64_t phase;
    int32_t active;
    int64_t head_len;
    int64_t why_len;
    uint8_t head[IF_HEAD_MAX];
    uint8_t why[IF_WHY_MAX];
} gweb_if_slot;

static gweb_if_slot *table;
static int64_t table_n;
static volatile int32_t dev_flag;   /* set once by init, before workers start; read by every thread */

static gweb_if_slot *slot_of(int64_t slot) {
    if (!table || slot < 0 || slot >= table_n) return NULL;
    return &table[slot];
}

/* Whether the server runs under gweb dev. */
int32_t gweb_inflight_dev(void) { return dev_flag; }

/* Call once, before any worker starts. Replaces an earlier table. dev: nonzero under gweb dev. */
void gweb_inflight_init(int64_t n, int32_t dev) {
    dev_flag = dev ? 1 : 0;
    free(table);
    table = NULL;
    table_n = 0;
    if (n <= 0) return;
    table = calloc((size_t)n, sizeof *table);
    if (!table) return;
    table_n = n;
    for (int64_t i = 0; i < n; i++) { table[i].fd = -1; table[i].route = -1; }
}

void gweb_inflight_set_loop(int64_t slot, uint64_t handle) {
    gweb_if_slot *s = slot_of(slot);
    if (s) s->loop = handle;
}

/* The registered loop handle, 0 when none. */
uint64_t gweb_inflight_loop(int64_t slot) {
    gweb_if_slot *s = slot_of(slot);
    return s ? s->loop : 0;
}

/* The saved head is the request line and header lines: the bytes before the first CRLF CRLF, with no final CRLF.
   Over 8 KiB it is cut before the last CRLF that fits, so it still ends at a line end. A re-parse appends CRLF CRLF.
   Only the first IF_HEAD_MAX + 4 bytes of raw are looked at; the body is never copied. */
void gweb_inflight_begin(int64_t slot, int32_t fd, gweb_ifbytes raw) {
    gweb_if_slot *s = slot_of(slot);
    if (!s) return;
    int64_t limit = raw.len < IF_HEAD_MAX + 4 ? raw.len : IF_HEAD_MAX + 4;
    int64_t end = -1;                       /* index of the first CRLF CRLF */
    for (int64_t i = 0; i + 3 < limit; i++) {
        if (raw.data[i] == '\r' && raw.data[i + 1] == '\n' && raw.data[i + 2] == '\r' && raw.data[i + 3] == '\n') { end = i; break; }
    }
    int64_t len;
    if (end >= 0) {
        len = end;
    } else {
        /* no blank line in the window: cut before the last CRLF that starts inside the first IF_HEAD_MAX bytes */
        len = 0;
        int64_t top = raw.len < IF_HEAD_MAX ? raw.len : IF_HEAD_MAX;
        for (int64_t i = 0; i + 1 < top; i++) {
            if (raw.data[i] == '\r' && raw.data[i + 1] == '\n') len = i;
        }
    }
    if (len > IF_HEAD_MAX) len = IF_HEAD_MAX;
    memcpy(s->head, raw.data, (size_t)len);
    s->head_len = len;
    s->fd = fd;
    s->route = -1;
    s->phase = 0;
    s->why_len = 0;
    s->active = 1;
}

void gweb_inflight_set_route(int64_t slot, int64_t route) {
    gweb_if_slot *s = slot_of(slot);
    if (s) s->route = route;
}

int64_t gweb_inflight_get_route(int64_t slot) {
    gweb_if_slot *s = slot_of(slot);
    return s ? s->route : -1;
}

/* 0: running the page or route; 1: rendering an error page (a crash then starts at attempt 2). */
void gweb_inflight_set_phase(int64_t slot, int64_t phase) {
    gweb_if_slot *s = slot_of(slot);
    if (s) s->phase = phase;
}

int64_t gweb_inflight_get_phase(int64_t slot) {
    gweb_if_slot *s = slot_of(slot);
    return s ? s->phase : 0;
}

int32_t gweb_inflight_fd(int64_t slot) {
    gweb_if_slot *s = slot_of(slot);
    return s ? s->fd : -1;
}

/* After the reply is sent. */
void gweb_inflight_end(int64_t slot) {
    gweb_if_slot *s = slot_of(slot);
    if (!s) return;
    s->active = 0;
    s->fd = -1;
    s->head_len = 0;
    s->route = -1;
    s->phase = 0;
}

/* 1 while a request is in flight. */
int32_t gweb_inflight_pending(int64_t slot) {
    gweb_if_slot *s = slot_of(slot);
    return s ? s->active : 0;
}

/* The supervisor stores thread_wait's text; cut at IF_WHY_MAX. */
void gweb_inflight_set_why(int64_t slot, gweb_ifbytes why) {
    gweb_if_slot *s = slot_of(slot);
    if (!s || why.len < 0) return;
    int64_t n = why.len < IF_WHY_MAX ? why.len : IF_WHY_MAX;
    if (n > 0) memcpy(s->why, why.data, (size_t)n);
    s->why_len = n;
}

/* Append the saved head, or the why text, to out; return the byte count. */
int64_t gweb_inflight_take_head(int64_t slot, gs_rref out) {
    gweb_if_slot *s = slot_of(slot);
    if (!s || s->head_len <= 0) return 0;
    gs_bld_append(out, s->head, (size_t)s->head_len);
    return s->head_len;
}

int64_t gweb_inflight_take_why(int64_t slot, gs_rref out) {
    gweb_if_slot *s = slot_of(slot);
    if (!s || s->why_len <= 0) return 0;
    gs_bld_append(out, s->why, (size_t)s->why_len);
    return s->why_len;
}

/* The last resort: a fixed 500 written straight to the socket. Never blocks for long. */
void gweb_inflight_plain_500(int32_t fd) {
    static const char msg[] =
        "HTTP/1.1 500 Internal Server Error\r\n"
        "Content-Type: text/plain; charset=utf-8\r\n"
        "Content-Length: 26\r\n"
        "Connection: close\r\n"
        "\r\n"
        "500 Internal Server Error\n";
    if (fd < 0) return;
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    const char *p = msg;
    size_t left = sizeof msg - 1;
    int waits = 0;
    while (left > 0) {
#ifdef MSG_NOSIGNAL
        ssize_t w = send(fd, p, left, MSG_NOSIGNAL);
#else
        ssize_t w = send(fd, p, left, 0);
#endif
        if (w < 0) {
            if (errno == EINTR) continue;
            if ((errno == EAGAIN || errno == EWOULDBLOCK) && waits++ < 20) {
                struct pollfd pf = { fd, POLLOUT, 0 };
                poll(&pf, 1, 50);
                continue;
            }
            return;
        }
        p += w;
        left -= (size_t)w;
    }
}
