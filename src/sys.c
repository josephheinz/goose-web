#ifdef __linux__
#define _DEFAULT_SOURCE  /* getentropy under -std=c11 on glibc and musl */
#endif
#include <stdint.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/sysctl.h>
#endif
#if defined(__APPLE__) || defined(__linux__)
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

/* 1 on success; getentropy refuses more than 256 bytes. */
int32_t gweb_entropy(gweb_wbytes buf) {
    if (buf.len < 0 || buf.len > 256) return 0;
    return getentropy(buf.data, (size_t)buf.len) == 0;
}
