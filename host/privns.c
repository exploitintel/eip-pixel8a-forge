/* Run a command in a private mount namespace with an overlay on /system/etc. */
#define _GNU_SOURCE

#include <errno.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <unistd.h>

/* Android 17's arm64 loader requires PT_TLS alignment of at least 64 bytes. */
static _Thread_local volatile unsigned char tls_alignment_anchor
    __attribute__((aligned(64)));

int main(int argc, char **argv) {
    char opts[1024];

    tls_alignment_anchor = 0;
    if (argc < 4) {
        fprintf(stderr, "usage: privns UPPER WORK CMD [ARGS...]\n");
        return 2;
    }
    if (unshare(CLONE_NEWNS)) {
        perror("unshare");
        return 1;
    }
    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL)) {
        perror("make-rprivate");
        return 1;
    }
    snprintf(opts, sizeof(opts), "lowerdir=/system/etc,upperdir=%s,workdir=%s",
             argv[1], argv[2]);
    if (mount("overlay", "/system/etc", "overlay", 0, opts)) {
        perror("overlay /system/etc");
        return 1;
    }
    execv(argv[3], &argv[3]);
    perror("exec");
    return 1;
}
