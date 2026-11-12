#include <stdint.h>
#ifdef __APPLE__
#include <sys/sysctl.h>
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
