/* The transport between goose-web workers and the state owner (main).
   One AF_UNIX SOCK_STREAM socketpair per worker, made before the workers
   start. A frame is a 4-byte little-endian length and the payload (a
   to_bytes image). The owner poll()s every pair and serves ready requests
   round robin; each worker blocks for its own reply. */
#include "goose.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/time.h>

typedef struct { const uint8_t *data; int64_t len; } gweb_bytes;

typedef struct {
    int n;
    int *owner;     /* owner's end of pair i */
    int *worker;    /* worker's end of pair i */
    struct pollfd *pfds;
    int next;
} gweb_chans;

static int write_all(int fd, const uint8_t *p, size_t len) {
    while (len > 0) {
        ssize_t w = write(fd, p, len);
        if (w < 0) { if (errno == EINTR) continue; return 0; }
        p += w; len -= (size_t)w;
    }
    return 1;
}

static int read_all(int fd, uint8_t *p, size_t len) {
    while (len > 0) {
        ssize_t r = read(fd, p, len);
        if (r < 0) { if (errno == EINTR) continue; return 0; }
        if (r == 0) return 0;
        p += r; len -= (size_t)r;
    }
    return 1;
}

uint64_t gweb_chans_new(int32_t n) {
    gweb_chans *c = calloc(1, sizeof *c);
    if (!c) return 0;
    c->n = n;
    c->owner = calloc((size_t)n, sizeof(int));
    c->worker = calloc((size_t)n, sizeof(int));
    c->pfds = calloc((size_t)n, sizeof(struct pollfd));
    for (int i = 0; i < n; i++) {
        int sv[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) return 0;
        c->owner[i] = sv[0];
        c->worker[i] = sv[1];
#ifdef SO_NOSIGPIPE
        int one = 1;
        setsockopt(sv[0], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        setsockopt(sv[1], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    }
    return (uint64_t)(uintptr_t)c;
}

int32_t gweb_chans_worker_fd(uint64_t h, int32_t i) {
    gweb_chans *c = (gweb_chans *)(uintptr_t)h;
    return (i >= 0 && i < c->n) ? c->worker[i] : -1;
}

/* Sends one frame. 1 on success. */
int32_t gweb_send_frame(int32_t fd, gweb_bytes payload) {
    uint8_t len[4] = { (uint8_t)payload.len, (uint8_t)(payload.len >> 8),
                       (uint8_t)(payload.len >> 16), (uint8_t)(payload.len >> 24) };
    return write_all(fd, len, 4) && write_all(fd, payload.data, (size_t)payload.len);
}

/* Reads one frame and appends its payload to out. 1 on success; 0 on an
   error, the end of the stream, or (with SO_RCVTIMEO set) a timeout. */
int32_t gweb_recv_frame(int32_t fd, gs_rref out) {
    uint8_t len[4];
    if (!read_all(fd, len, 4)) return 0;
    size_t n = (size_t)len[0] | (size_t)len[1] << 8 | (size_t)len[2] << 16 | (size_t)len[3] << 24;
    uint8_t stack[4096];
    uint8_t *buf = n <= sizeof stack ? stack : malloc(n);
    if (!buf) return 0;
    int ok = read_all(fd, buf, n);
    if (ok) gs_bld_append(out, buf, n);
    if (buf != stack) free(buf);
    return ok;
}

/* Receive timeout for a worker's end, in milliseconds. */
void gweb_set_recv_timeout(int32_t fd, int64_t ms) {
    struct timeval tv = { (time_t)(ms / 1000), (suseconds_t)((ms % 1000) * 1000) };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
}

/* The owner waits for the next request from any worker, round robin, and
   appends its payload to out. Returns the worker index, or -1 on an error. */
int32_t gweb_owner_next(uint64_t h, gs_rref out) {
    gweb_chans *c = (gweb_chans *)(uintptr_t)h;
    for (;;) {
        for (int i = 0; i < c->n; i++) c->pfds[i] = (struct pollfd){ c->owner[i], POLLIN, 0 };
        int r = poll(c->pfds, (nfds_t)c->n, -1);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        for (int k = 0; k < c->n; k++) {
            int i = (c->next + k) % c->n;
            if (c->pfds[i].revents & (POLLIN | POLLHUP)) {
                c->next = (i + 1) % c->n;
                if (gweb_recv_frame(c->owner[i], out)) return i;
                /* That worker's end closed: stop polling it. */
                close(c->owner[i]);
                c->owner[i] = -1;
            }
        }
    }
}

int32_t gweb_owner_fd(uint64_t h, int32_t i) {
    gweb_chans *c = (gweb_chans *)(uintptr_t)h;
    return (i >= 0 && i < c->n) ? c->owner[i] : -1;
}
