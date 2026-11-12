/* Tests for src/upload.c: every helper, against a stub goose.h. */
#include "goose.h"
#include <stdio.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>

typedef struct { const uint8_t *data; int64_t len; } bytes;
int64_t gweb_up_getpid(void);
int32_t gweb_up_open_read(bytes);
int64_t gweb_up_size(int32_t);
int64_t gweb_up_pread(int32_t, int64_t, int64_t, gs_rref);
int32_t gweb_up_create(bytes);
int32_t gweb_up_write(int32_t, bytes);
void gweb_up_close(int32_t);
int32_t gweb_up_unlink(bytes);
int32_t gweb_up_save(bytes, bytes);
int32_t gweb_up_mkdir(bytes);
int64_t gweb_up_sweep(bytes);

static int failures, checks;
#define CHECK(c) do { checks++; if (!(c)) { failures++; printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

static bytes B(const char *s) { bytes b = { (const uint8_t *)s, (int64_t)strlen(s) }; return b; }
static int exists(const char *p) { struct stat st; return stat(p, &st) == 0; }

static void put(const char *path, const char *data, size_t n) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0 || write(fd, data, n) != (ssize_t)n) { perror("put"); exit(2); }
    close(fd);
}

static int same(const char *path, const char *data, size_t n) {
    char buf[256];
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    ssize_t r = read(fd, buf, sizeof buf);
    close(fd);
    return r == (ssize_t)n && memcmp(buf, data, n) == 0;
}

int main(void) {
    char root[] = "/tmp/gweb-upc.XXXXXX";
    if (!mkdtemp(root)) { perror("mkdtemp"); return 2; }
    char p[512], q[512], cmd[600];

    CHECK(gweb_up_getpid() == (int64_t)getpid());

    /* mkdir -p */
    snprintf(p, sizeof p, "%s/a/b/up", root);
    CHECK(gweb_up_mkdir(B(p)) == 1);
    CHECK(exists(p));
    CHECK(gweb_up_mkdir(B(p)) == 1);                   /* exists: still 1 */
    snprintf(q, sizeof q, "%s/file", root);
    put(q, "x", 1);
    CHECK(gweb_up_mkdir(B(q)) == 0);                   /* a file is not a directory */
    CHECK(gweb_up_mkdir(B("")) == 0);

    /* create is exclusive, 0600; write appends */
    char up[512];
    snprintf(up, sizeof up, "%s/a/b/up", root);
    snprintf(p, sizeof p, "%s/gw-1-0-0", up);
    int fd = gweb_up_create(B(p));
    CHECK(fd >= 0);
    CHECK(gweb_up_write(fd, B("hello ")) == 1);
    CHECK(gweb_up_write(fd, B("world")) == 1);
    CHECK(gweb_up_write(fd, (bytes){ (const uint8_t *)"", 0 }) == 1);
    gweb_up_close(fd);
    CHECK(same(p, "hello world", 11));
    struct stat st;
    CHECK(stat(p, &st) == 0 && (st.st_mode & 0777) == 0600);
    CHECK(gweb_up_create(B(p)) < 0);                   /* O_EXCL */
    CHECK(same(p, "hello world", 11));                 /* untouched */
    CHECK(gweb_up_write(-1, B("x")) == 0);

    /* open_read, size, pread windows */
    int rd = gweb_up_open_read(B(p));
    CHECK(rd >= 0);
    CHECK(gweb_up_size(rd) == 11);
    gs_buf out = { 0 };
    CHECK(gweb_up_pread(rd, 0, 5, &out) == 5);
    CHECK(out.len == 5 && memcmp(out.data, "hello", 5) == 0);
    CHECK(gweb_up_pread(rd, 6, 100, &out) == 5);       /* short at the end, appended */
    CHECK(out.len == 10 && memcmp(out.data + 5, "world", 5) == 0);
    CHECK(gweb_up_pread(rd, 11, 10, &out) == 0);       /* at the end */
    CHECK(gweb_up_pread(rd, 50, 10, &out) == 0);       /* past the end */
    CHECK(out.len == 10);
    CHECK(gweb_up_pread(rd, -1, 10, &out) == -1);
    CHECK(gweb_up_pread(-1, 0, 10, &out) == -1);
    CHECK(gweb_up_size(-1) == -1);
    gweb_up_close(rd);
    CHECK(gweb_up_open_read(B("/nonexistent/zzz")) < 0);
    CHECK(gweb_up_open_read(B("")) < 0);

    /* a larger file read in windows adds up */
    {
        size_t n = 200000;
        uint8_t *big = malloc(n);
        for (size_t i = 0; i < n; i++) big[i] = (uint8_t)(i * 7);
        snprintf(q, sizeof q, "%s/big", root);
        put(q, (const char *)big, n);
        int bf = gweb_up_open_read(B(q));
        gs_buf all = { 0 };
        int64_t off = 0, got;
        while ((got = gweb_up_pread(bf, off, 65536, &all)) > 0) off += got;
        CHECK(off == (int64_t)n && all.len == n && memcmp(all.data, big, n) == 0);
        CHECK(gweb_up_size(bf) == (int64_t)n);
        gweb_up_close(bf);
        free(big);
    }

    /* save: link and unlink, no overwrite */
    char dest[512], dest2[512];
    snprintf(dest, sizeof dest, "%s/saved.txt", root);
    CHECK(gweb_up_save(B(p), B(dest)) == 1);
    CHECK(same(dest, "hello world", 11));
    CHECK(!exists(p));                                 /* the temp path is gone */
    snprintf(p, sizeof p, "%s/gw-1-0-1", up);
    put(p, "second", 6);
    CHECK(gweb_up_save(B(p), B(dest)) == 0);           /* refuses an existing dest */
    CHECK(same(dest, "hello world", 11));
    CHECK(same(p, "second", 6));                       /* source kept */
    snprintf(dest2, sizeof dest2, "%s/nodir/x", root);
    CHECK(gweb_up_save(B(p), B(dest2)) == 0);          /* no such directory: copy fails too */
    CHECK(same(p, "second", 6));
    snprintf(dest2, sizeof dest2, "%s/saved2.txt", root);
    CHECK(gweb_up_save(B("/nonexistent/zzz"), B(dest2)) == 0);
    CHECK(!exists(dest2));
    CHECK(gweb_up_save(B(p), B(dest2)) == 1);
    CHECK(same(dest2, "second", 6));

    /* the copy path (the fallback for another file system), through a dangling-link-free route:
       a source that link() refuses with a non-EEXIST error is a directory */
    snprintf(q, sizeof q, "%s/srcdir", root);
    mkdir(q, 0700);
    snprintf(dest2, sizeof dest2, "%s/fromdir", root);
    CHECK(gweb_up_save(B(q), B(dest2)) == 0);          /* copy of a directory fails and leaves nothing */
    CHECK(!exists(dest2));

    /* unlink */
    snprintf(p, sizeof p, "%s/gw-1-0-2", up);
    put(p, "z", 1);
    CHECK(gweb_up_unlink(B(p)) == 1);
    CHECK(!exists(p));
    CHECK(gweb_up_unlink(B(p)) == 0);                  /* already gone */
    CHECK(gweb_up_unlink(B("")) == 0);

    /* sweep: gnet- and gw- regular files only */
    char names[][32] = { "gnet-1-1", "gw-9-0-3", "keep.txt", "gwx", "gnetx", "Gw-1" };
    for (int i = 0; i < 6; i++) {
        snprintf(p, sizeof p, "%s/%s", up, names[i]);
        put(p, "d", 1);
    }
    snprintf(p, sizeof p, "%s/gw-dir", up);
    mkdir(p, 0700);                                     /* a directory is never removed */
    snprintf(q, sizeof q, "%s/gw-link", up);
    symlink(dest, q);                                   /* a link is left alone, and so is its target */
    CHECK(gweb_up_sweep(B(up)) == 2);
    for (int i = 0; i < 6; i++) {
        snprintf(p, sizeof p, "%s/%s", up, names[i]);
        CHECK(exists(p) == (i >= 2));
    }
    snprintf(p, sizeof p, "%s/gw-dir", up);
    CHECK(exists(p));
    CHECK(exists(dest));
    CHECK(gweb_up_sweep(B(up)) == 0);
    CHECK(gweb_up_sweep(B("/nonexistent/zzz")) == -1);
    CHECK(gweb_up_sweep(B("")) == -1);

    snprintf(cmd, sizeof cmd, "rm -rf %s", root);
    if (system(cmd) != 0) return 2;
    printf("%d checks, %d failures\n", checks, failures);
    return failures != 0;
}
