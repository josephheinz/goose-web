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

/* otel.c. Trace and span ids are lower-case hex text: 32 chars for a trace, 16 for a span.
   gweb_trace_parse: 1 and the ids appended to the two builders (and *sampled set) for a valid version-00
   traceparent; 0 and nothing appended otherwise.
   gweb_trace_start: parent_sampled is -1 (no parent), 0 or 1; a parent's flag wins, else the ratio decides
   from the trace id (TraceIdRatioBased: lower 8 bytes, big-endian, below ratio * 2^64), so it is deterministic.
   gweb_otel_sample applies the configured sampler (off, or parent-based or not, with the configured ratio).
   gweb_span_push: 1 stored, 0 dropped (ring of 8192 full, or bad ids; both counted). parent is empty for a root;
   kind 1 internal, 2 server; status 0 unset, 2 error; method, route, path empty and http_status 0 are omitted
   (name truncated to 128 bytes, path to 256). One generic attribute: attr_key (up to 32 bytes) with attr_val
   (up to 64): a string, or with attr_is_int a decimal exported as an int (job spans: "job.attempt", "2").
   gweb_otel_start_from_env: 0 off, 1 on, 2 refused (https or unusable endpoint; one warning on stderr).
   gweb_otel_flush: sends the queue, waits up to timeout_ms, stops the exporter; 1 when finished, 0 on timeout. */
int64_t gweb_unix_ns(void);
int32_t gweb_trace_parse(gweb_bytes header, gs_rref trace_out, gs_rref parent_out, int32_t *sampled);
int32_t gweb_trace_ratio_sampled(gweb_bytes trace_id, double ratio);
int32_t gweb_trace_start(int32_t parent_sampled, gweb_bytes trace_id, double ratio);
int32_t gweb_otel_sample(int32_t parent_sampled, gweb_bytes trace_id);
void gweb_traceparent(gs_rref out, gweb_bytes trace, gweb_bytes span, int32_t sampled);
int32_t gweb_span_push(gweb_bytes trace, gweb_bytes span, gweb_bytes parent, gweb_bytes name, int32_t kind,
                       int64_t start_ns, int64_t end_ns, int32_t status, gweb_bytes method, gweb_bytes route,
                       gweb_bytes path, int32_t http_status, gweb_bytes attr_key, gweb_bytes attr_val,
                       int32_t attr_is_int);
int32_t gweb_otel_start_from_env(void);
int32_t gweb_otel_on(void);
double gweb_otel_ratio(void);
int32_t gweb_otel_parent_based(void);
int32_t gweb_otel_flush(int32_t timeout_ms);

/* Read by gweb_metrics_render. obs.c has weak stubs that return 0; otel.c and jobs.c define the real ones.
   which: 0 queued, 1 running, 2 completed, 3 failed attempts, 4 dropped, 5 rejected. */
int64_t gweb_jobs_stat(int32_t which);
int64_t gweb_spans_dropped(void);

#endif
