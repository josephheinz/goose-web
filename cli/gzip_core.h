#ifndef GWEB_GZIP_CORE_H
#define GWEB_GZIP_CORE_H
#include <stddef.h>
#include <stdint.h>

/* Compresses in[0..n) as a gzip stream into a malloc'd buffer. Returns 1 on
   success (caller frees *out), 0 on failure. */
int gweb_gzip_core(const uint8_t *in, size_t n, uint8_t **out, size_t *outlen);
#endif
