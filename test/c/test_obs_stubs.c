/* Without src/otel.c and src/jobs.c linked, the weak stubs report zeros. */
#include "goose.h"
#include "ops.h"
#include "check.h"

int main(void) {
    for (int i = 0; i < 6; i++) CHECK(gweb_jobs_stat(i) == 0);
    CHECK(gweb_spans_dropped() == 0);
    gs_buf b = {0};
    gweb_metrics_render(&b, (gweb_bytes){(const uint8_t *)"x", 1});
    CHECK(b.len > 0 && strstr(b.data, "gweb_jobs_queued 0\n") && strstr(b.data, "gweb_spans_dropped_total 0\n"));
    return done();
}
