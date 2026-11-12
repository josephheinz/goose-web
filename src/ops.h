/* Declarations shared by src/obs.c, src/otel.c and src/jobs.c. */
#ifndef GWEB_OPS_H
#define GWEB_OPS_H

#include "goose.h"

#include <stdint.h>

typedef struct { const uint8_t *data; int64_t len; } gweb_bytes;

/* obs.c */
int64_t gweb_now_us(void);
void gweb_rfc3339(gs_rref out);
void gweb_rand_hex(gs_rref out, int32_t nbytes);
void gweb_log_line(gweb_bytes line);
void gweb_log_config(int32_t level, int32_t json);
int32_t gweb_log_level(void);
int32_t gweb_log_json(void);
void gweb_metrics_init(int32_t workers, gweb_bytes route_names_nl);
int32_t gweb_metrics_on(void);
void gweb_metrics_request(int32_t worker, int32_t route, int32_t method, int32_t status, int64_t dur_us);
void gweb_metrics_conn(int32_t worker, int64_t open_count);
void gweb_metric_count(gweb_bytes name, int64_t n);
void gweb_metric_gauge(gweb_bytes name, double v);
void gweb_metrics_render(gs_rref out, gweb_bytes version);

/* Read by gweb_metrics_render. obs.c has weak stubs that return 0; otel.c and jobs.c define the real ones.
   which: 0 queued, 1 running, 2 completed, 3 failed attempts, 4 dropped, 5 rejected. */
int64_t gweb_jobs_stat(int32_t which);
int64_t gweb_spans_dropped(void);

#endif
