/* File helpers for web::upload: windowed reads of a spool file, temp files created with O_EXCL,
   saving without overwrite, and the start-up sweep. Every function is small and returns 1/0 or a count. */
#include "goose.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/stat.h>

typedef struct { const uint8_t *data; int64_t len; } gweb_up_bytes;

#define UP_PATH_MAX 1024
#define UP_WINDOW_MAX (1 << 20)

/* Copies a slice into a NUL-terminated buffer; 0 when empty, too long or holding a NUL byte. */
static int cpath(gweb_up_bytes p, char *buf) {
    if (p.len <= 0 || p.len >= UP_PATH_MAX) return 0;
    if (memchr(p.data, 0, (size_t)p.len)) return 0;
    memcpy(buf, p.data, (size_t)p.len);
    buf[p.len] = 0;
    return 1;
}

static int write_all(int fd, const uint8_t *p, size_t len) {
    while (len > 0) {
        ssize_t w = write(fd, p, len);
        if (w < 0) { if (errno == EINTR) continue; return 0; }
        p += w; len -= (size_t)w;
    }
    return 1;
}

int64_t gweb_up_getpid(void) { return (int64_t)getpid(); }

/* The descriptor, or -1. */
int32_t gweb_up_open_read(gweb_up_bytes path) {
    char p[UP_PATH_MAX];
    if (!cpath(path, p)) return -1;
    int fd;
    do { fd = open(p, O_RDONLY | O_CLOEXEC); } while (fd < 0 && errno == EINTR);
    return fd;
}

/* The file size, or -1. */
int64_t gweb_up_size(int32_t fd) {
    struct stat st;
    if (fd < 0 || fstat(fd, &st) < 0) return -1;
    return (int64_t)st.st_size;
}

/* Appends up to n bytes read at off to out and returns how many (0 at the end of the file); -1 on an error. */
int64_t gweb_up_pread(int32_t fd, int64_t off, int64_t n, gs_rref out) {
    if (fd < 0 || off < 0 || n < 0) return -1;
    if (n > UP_WINDOW_MAX) n = UP_WINDOW_MAX;
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

/* Creates a new file, mode 0600, failing when the path exists. The descriptor, or -1. */
int32_t gweb_up_create(gweb_up_bytes path) {
    char p[UP_PATH_MAX];
    if (!cpath(path, p)) return -1;
    int fd;
    do { fd = open(p, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600); } while (fd < 0 && errno == EINTR);
    return fd;
}

/* Appends data at the end of the file; 1 when all of it was written. */
int32_t gweb_up_write(int32_t fd, gweb_up_bytes data) {
    if (fd < 0 || data.len < 0) return 0;
    return write_all(fd, data.data, (size_t)data.len);
}

void gweb_up_close(int32_t fd) { if (fd >= 0) close(fd); }

/* 1 when the file is gone. */
int32_t gweb_up_unlink(gweb_up_bytes path) {
    char p[UP_PATH_MAX];
    if (!cpath(path, p)) return 0;
    return unlink(p) == 0;
}

/* Copies src to a new dest, which must not exist. 1 on success; a failed copy leaves no dest. */
static int copy_new(const char *src, const char *dest) {
    int in = open(src, O_RDONLY | O_CLOEXEC);
    if (in < 0) return 0;
    int out = open(dest, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (out < 0) { close(in); return 0; }
    uint8_t buf[65536];
    int ok = 1;
    for (;;) {
        ssize_t r = read(in, buf, sizeof buf);
        if (r < 0) { if (errno == EINTR) continue; ok = 0; break; }
        if (r == 0) break;
        if (!write_all(out, buf, (size_t)r)) { ok = 0; break; }
    }
    close(in);
    if (close(out) < 0) ok = 0;
    if (!ok) unlink(dest);
    return ok;
}

/* Moves src to dest and never overwrites: link then unlink; where link fails for another reason
   than an existing dest (another file system), copy with O_EXCL then unlink. 1 on success. */
int32_t gweb_up_save(gweb_up_bytes src, gweb_up_bytes dest) {
    char s[UP_PATH_MAX], d[UP_PATH_MAX];
    if (!cpath(src, s) || !cpath(dest, d)) return 0;
    if (link(s, d) == 0) { unlink(s); return 1; }
    if (errno == EEXIST) return 0;
    if (!copy_new(s, d)) return 0;
    unlink(s);
    return 1;
}

/* mkdir -p, mode 0700. 1 when the directory exists afterwards. */
int32_t gweb_up_mkdir(gweb_up_bytes path) {
    char p[UP_PATH_MAX];
    struct stat st;
    if (!cpath(path, p)) return 0;
    for (char *c = p + 1; *c; c++) {
        if (*c != '/') continue;
        *c = 0;
        if (mkdir(p, 0700) < 0 && errno != EEXIST) return 0;
        *c = '/';
    }
    if (mkdir(p, 0700) < 0 && errno != EEXIST) return 0;
    return stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

/* Deletes the regular files in dir whose names start with gnet- or gw-. The count deleted, or -1 when dir cannot be read. */
int64_t gweb_up_sweep(gweb_up_bytes dir) {
    char p[UP_PATH_MAX];
    if (!cpath(dir, p)) return -1;
    DIR *d = opendir(p);
    if (!d) return -1;
    int64_t n = 0;
    int dfd = dirfd(d);
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strncmp(e->d_name, "gnet-", 5) != 0 && strncmp(e->d_name, "gw-", 3) != 0) continue;
        struct stat st;
        if (fstatat(dfd, e->d_name, &st, AT_SYMLINK_NOFOLLOW) < 0 || !S_ISREG(st.st_mode)) continue;
        if (unlinkat(dfd, e->d_name, 0) == 0) n++;
    }
    closedir(d);
    return n;
}
