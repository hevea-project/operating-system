/*
 * kmount.c — tiny static mount(2) wrapper for the diskless-boot initramfs
 * (the HAOS buildroot busybox has no mount applet).
 *
 * Usage: kmount [-t fstype] [-o opts] <dev> <dir>
 *        kmount -o move <src> <dst>     (for moving /proc /sys /dev)
 *
 * Build: aarch64-buildroot-linux-gnu-gcc -O2 -static -o kmount kmount.c
 */
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>

int main(int argc, char **argv)
{
    const char *type = NULL, *opts = NULL, *src = NULL, *dst = NULL;
    int flags = 0;
    int i = 1;
    for (; i < argc; i++) {
        if (!strcmp(argv[i], "-t") && i + 1 < argc) {
            type = argv[++i];
        } else if (!strcmp(argv[i], "-o") && i + 1 < argc) {
            opts = argv[++i];
            if (strstr(opts, "ro"))
                flags |= MS_RDONLY;
            if (strstr(opts, "move"))
                flags |= MS_MOVE;
            if (strstr(opts, "bind"))
                flags |= MS_BIND;
        } else if (!src) {
            src = argv[i];
        } else {
            dst = argv[i];
        }
    }
    if (!src || !dst) {
        fprintf(stderr, "usage: kmount [-t type] [-o opts] <src> <dst>\n");
        return 2;
    }
    if (mount(src, dst, type, flags, NULL) < 0) {
        perror("mount");
        return 1;
    }
    return 0;
}
