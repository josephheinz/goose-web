/* The owner transport's quit path: -3 after every user has left, pending frames first. */
#include "goose.h"
#include "check.h"

#include <pthread.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

/* owner.c defines its own copy of this type; it is not shared through ops.h. */
typedef struct { const uint8_t *data; int64_t len; } gweb_bytes;

uint64_t gweb_chans_new(int32_t n);
int32_t gweb_chans_worker_fd(uint64_t h, int32_t i);
int32_t gweb_send_frame(int32_t fd, gweb_bytes payload);
int32_t gweb_owner_next(uint64_t h, gs_rref out);
void gweb_chans_leave(uint64_t h);

static gweb_bytes bytes(const char *s) { return (gweb_bytes){ (const uint8_t *)s, (int64_t)strlen(s) }; }

static void *late_leaves(void *arg) {
    uint64_t h = *(uint64_t *)arg;
    usleep(100 * 1000);
    gweb_chans_leave(h);
    gweb_chans_leave(h);
    return NULL;
}

int main(void) {
    gweb_chans_leave(0);   /* a no-op for a handle that was never made */

    /* A pending frame is served before -3, and -3 repeats. */
    uint64_t h = gweb_chans_new(3);
    CHECK(h != 0);
    CHECK(gweb_send_frame(gweb_chans_worker_fd(h, 1), bytes("hello")) == 1);
    gweb_chans_leave(h);
    gweb_chans_leave(h);
    gweb_chans_leave(h);
    gs_buf out = {0};
    CHECK(gweb_owner_next(h, &out) == 1);
    CHECK(out.len == 5 && memcmp(out.data, "hello", 5) == 0);
    free(out.data);
    out = (gs_buf){0};
    CHECK(gweb_owner_next(h, &out) == -3);
    CHECK(out.len == 0);
    CHECK(gweb_owner_next(h, &out) == -3);

    /* Not every user has left: the owner keeps serving; the last leave, from another thread, wakes it. */
    uint64_t h2 = gweb_chans_new(3);
    gweb_chans_leave(h2);
    CHECK(gweb_send_frame(gweb_chans_worker_fd(h2, 2), bytes("x")) == 1);
    gs_buf o2 = {0};
    CHECK(gweb_owner_next(h2, &o2) == 2);
    CHECK(o2.len == 1 && o2.data[0] == 'x');
    free(o2.data);
    o2 = (gs_buf){0};
    pthread_t t;
    pthread_create(&t, NULL, late_leaves, &h2);
    CHECK(gweb_owner_next(h2, &o2) == -3);
    pthread_join(t, NULL);
    free(o2.data);

    /* A worker that closed its end does not end the loop by itself. */
    uint64_t h3 = gweb_chans_new(2);
    close(gweb_chans_worker_fd(h3, 0));
    CHECK(gweb_send_frame(gweb_chans_worker_fd(h3, 1), bytes("y")) == 1);
    gs_buf o3 = {0};
    CHECK(gweb_owner_next(h3, &o3) == 1);
    free(o3.data);
    o3 = (gs_buf){0};
    gweb_chans_leave(h3);
    gweb_chans_leave(h3);
    CHECK(gweb_owner_next(h3, &o3) == -3);
    return done();
}
