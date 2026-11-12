/* Process and file-tree helpers for gweb: run with captured output, spawn,
   kill, wait, exec, symlink, chdir, cwd, remove a tree, and a change stamp
   (file count and newest mtime) for the dev watcher. POSIX only. */
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#include "goose.h"

#include <errno.h>
#include <ftw.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

typedef struct { const uint8_t *data; int64_t len; } gweb_bytes;

static char *cstr(gweb_bytes s) {
    char *p = malloc((size_t)s.len + 1);
    if (!p) return NULL;
    memcpy(p, s.data, (size_t)s.len);
    p[s.len] = 0;
    return p;
}

/* Runs cmd with /bin/sh, appends its stdout and stderr to out, and returns
   its exit status (-1 when it could not run or did not exit normally). */
int32_t gweb_run(gweb_bytes cmd, gs_rref out) {
    char *c = cstr(cmd);
    if (!c) return -1;
    size_t n = strlen(c);
    char *full = malloc(n + 16);
    memcpy(full, c, n);
    memcpy(full + n, " 2>&1", 6);
    free(c);
    FILE *f = popen(full, "r");
    free(full);
    if (!f) return -1;
    char buf[8192];
    size_t r;
    while ((r = fread(buf, 1, sizeof buf, f)) > 0) gs_bld_append(out, buf, r);
    int st = pclose(f);
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

/* Starts cmd with /bin/sh -c "exec cmd" and returns its pid, or -1. */
int64_t gweb_spawn(gweb_bytes cmd) {
    char *c = cstr(cmd);
    if (!c) return -1;
    size_t n = strlen(c);
    char *full = malloc(n + 8);
    memcpy(full, "exec ", 5);
    memcpy(full + 5, c, n + 1);
    free(c);
    char *argv[] = { "sh", "-c", full, NULL };
    pid_t pid;
    int rc = posix_spawn(&pid, "/bin/sh", NULL, NULL, argv, environ);
    free(full);
    return rc == 0 ? (int64_t)pid : -1;
}

/* Replaces this process with cmd under /bin/sh. Returns only on failure. */
int32_t gweb_exec(gweb_bytes cmd) {
    char *c = cstr(cmd);
    if (!c) return -1;
    size_t n = strlen(c);
    char *full = malloc(n + 8);
    memcpy(full, "exec ", 5);
    memcpy(full + 5, c, n + 1);
    free(c);
    fflush(stdout);
    execl("/bin/sh", "sh", "-c", full, (char *)NULL);
    free(full);
    return -1;
}

int32_t gweb_kill(int64_t pid, int32_t sig) { return kill((pid_t)pid, sig) == 0; }

/* With block 0: -2 while the child runs, else its exit status (or -1). */
int32_t gweb_wait(int64_t pid, int32_t block) {
    int st;
    pid_t r = waitpid((pid_t)pid, &st, block ? 0 : WNOHANG);
    if (r == 0) return -2;
    if (r < 0) return -1;
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

int32_t gweb_symlink(gweb_bytes target, gweb_bytes path) {
    char *t = cstr(target), *p = cstr(path);
    int ok = t && p && symlink(t, p) == 0;
    free(t); free(p);
    return ok;
}

int32_t gweb_chdir(gweb_bytes path) {
    char *p = cstr(path);
    int ok = p && chdir(p) == 0;
    free(p);
    return ok;
}

int32_t gweb_cwd(gs_rref out) {
    char buf[4096];
    if (!getcwd(buf, sizeof buf)) return 0;
    gs_bld_append(out, buf, strlen(buf));
    return 1;
}

static int rm_one(const char *path, const struct stat *sb, int flag, struct FTW *ftw) {
    (void)sb; (void)ftw;
    return (flag == FTW_DP ? rmdir(path) : unlink(path)) == 0 ? 0 : -1;
}

/* Removes path and everything under it, without following symlinks. */
int32_t gweb_remove_tree(gweb_bytes path) {
    char *p = cstr(path);
    if (!p) return 0;
    struct stat st;
    int ok = 1;
    if (lstat(p, &st) == 0) ok = nftw(p, rm_one, 32, FTW_DEPTH | FTW_PHYS) == 0;
    free(p);
    return ok;
}

static int64_t stamp_count, stamp_newest;
static int stamp_one(const char *path, const struct stat *sb, int flag, struct FTW *ftw) {
    (void)path; (void)ftw;
    if (flag == FTW_F || flag == FTW_D || flag == FTW_SL) {
        stamp_count++;
#ifdef __APPLE__
        int64_t t = (int64_t)sb->st_mtimespec.tv_sec * 1000000000 + sb->st_mtimespec.tv_nsec;
#else
        int64_t t = (int64_t)sb->st_mtim.tv_sec * 1000000000 + sb->st_mtim.tv_nsec;
#endif
        if (t > stamp_newest) stamp_newest = t;
    }
    return 0;
}

/* Adds the number of entries under path to count and returns the newest
   mtime in nanoseconds (0 when path is missing). Follows symlinks. */
int64_t gweb_tree_stamp(gweb_bytes path, int64_t *count) {
    char *p = cstr(path);
    if (!p) return 0;
    stamp_count = 0;
    stamp_newest = 0;
    struct stat st;
    if (stat(p, &st) == 0) nftw(p, stamp_one, 32, 0);
    free(p);
    *count += stamp_count;
    return stamp_newest;
}
