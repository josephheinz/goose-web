#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/sysctl.h>
#include <sys/random.h>
#endif

/* 0 when unknown. */
int64_t gweb_performance_cores(void) {
#ifdef __APPLE__
    int n = 0;
    size_t len = sizeof n;
    if (sysctlbyname("hw.perflevel0.logicalcpu", &n, &len, NULL, 0) == 0 && n > 0) return n;
#endif
    return 0;
}

typedef struct { uint8_t *data; int64_t len; } gweb_wbytes;
typedef struct { const uint8_t *data; int64_t len; } gweb_bytes;

/* 1 on success; getentropy refuses more than 256 bytes. */
int32_t gweb_entropy(gweb_wbytes buf) {
    if (buf.len < 0 || buf.len > 256) return 0;
    return getentropy(buf.data, (size_t)buf.len) == 0;
}

/* setenv without overwrite: 1 on success or when already set; 0 on failure, an empty name, '=' or NUL in
   the name, or NUL in the value. Call before any thread starts. */
int32_t gweb_setenv(gweb_bytes name, gweb_bytes value) {
    if (name.len <= 0 || name.len > 4096 || value.len < 0 || value.len > 65536) return 0;
    if (memchr(name.data, '=', (size_t)name.len) || memchr(name.data, 0, (size_t)name.len)) return 0;
    if (value.len > 0 && memchr(value.data, 0, (size_t)value.len)) return 0;
    char *n = malloc((size_t)name.len + 1), *v = malloc((size_t)value.len + 1);
    int32_t ok = 0;
    if (n && v) {
        memcpy(n, name.data, (size_t)name.len);
        n[name.len] = 0;
        if (value.len > 0) memcpy(v, value.data, (size_t)value.len);
        v[value.len] = 0;
        ok = setenv(n, v, 0) == 0;
    }
    free(n);
    free(v);
    return ok;
}
