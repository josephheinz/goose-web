#ifdef __linux__
#define _DEFAULT_SOURCE  /* realpath, pread and st_mtim under -std=c11 on glibc and musl */
#endif
/* Files for gweb::send_file: open a file under a root and refuse anything that resolves outside it
   (symlinks included), then read it in windows. Each function is small and returns a count or a code. */
#include "goose.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>

typedef struct { const uint8_t *data; int64_t len; } gweb_file_bytes;

#define FILE_PATH_MAX 4096
#define FILE_WINDOW_MAX (1 << 20)

/* Opens root/rel for reading. Returns the descriptor and sets size and mtime_ns, or
   -1 when there is no such regular file, -2 when the real path is not inside the real root.
   Both paths are resolved with realpath, so a symlink that leaves the root is refused. */
int32_t gweb_file_open_in(gweb_file_bytes root, gweb_file_bytes rel, int64_t *size, int64_t *mtime_ns) {
    char joined[FILE_PATH_MAX], rroot[PATH_MAX], rfull[PATH_MAX];
    if (root.len <= 0 || rel.len <= 0 || root.len + rel.len + 2 >= FILE_PATH_MAX) return -1;
    if (memchr(root.data, 0, (size_t)root.len) || memchr(rel.data, 0, (size_t)rel.len)) return -1;
    memcpy(joined, root.data, (size_t)root.len);
    size_t n = (size_t)root.len;
    if (joined[n - 1] != '/') joined[n++] = '/';
    memcpy(joined + n, rel.data, (size_t)rel.len);
    joined[n + (size_t)rel.len] = 0;
    char r[FILE_PATH_MAX];
    memcpy(r, root.data, (size_t)root.len);
    r[root.len] = 0;
    if (!realpath(r, rroot)) return -1;
    if (!realpath(joined, rfull)) return -1;
    size_t rl = strlen(rroot);
    if (strncmp(rfull, rroot, rl) != 0) return -2;
    if (rl > 1 && rfull[rl] != '/') return -2;
    int fd;
    /* O_NONBLOCK: opening a FIFO must not wait for a writer. It does nothing for a regular file. */
    do { fd = open(rfull, O_RDONLY | O_CLOEXEC | O_NONBLOCK); } while (fd < 0 && errno == EINTR);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode)) { close(fd); return -1; }
    if (size) *size = (int64_t)st.st_size;
    if (mtime_ns) {
#ifdef __APPLE__
        *mtime_ns = (int64_t)st.st_mtimespec.tv_sec * 1000000000LL + st.st_mtimespec.tv_nsec;
#else
        *mtime_ns = (int64_t)st.st_mtim.tv_sec * 1000000000LL + st.st_mtim.tv_nsec;
#endif
    }
    return fd;
}

/* Appends up to n bytes read at off to out and returns how many (0 at the end of the file); -1 on an error. */
int64_t gweb_file_pread(int32_t fd, int64_t off, int64_t n, gs_rref out) {
    if (fd < 0 || off < 0 || n < 0) return -1;
    if (n > FILE_WINDOW_MAX) n = FILE_WINDOW_MAX;
    uint8_t *buf = malloc((size_t)n + 1);
    if (!buf) return -1;
    int64_t got = 0;
    while (got < n) {
        ssize_t r = pread(fd, buf + got, (size_t)(n - got), (off_t)(off + got));
        if (r < 0) { if (errno == EINTR) continue; free(buf); return -1; }
        if (r == 0) break;
        got += r;
    }
    if (got > 0) gs_bld_append(out, buf, (size_t)got);
    free(buf);
    return got;
}

void gweb_file_close(int32_t fd) { if (fd >= 0) close(fd); }
