/*
 * kpart.c — trigger a partition-table rescan on a block device
 * (BLKRRPART ioctl). The HAOS busybox has no blockdev/partx applet.
 *
 * With the netlink NBD_CMD_CONNECT path the kernel does not set
 * GD_NEED_PART_SCAN, so partitions are not detected automatically.
 *
 * Build: aarch64-buildroot-linux-gnu-gcc -O2 -static -o kpart kpart.c
 */
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/fs.h>

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s /dev/nbdX\n", argv[0]);
        return 2;
    }
    int fd = open(argv[1], O_RDONLY | O_NONBLOCK);
    if (fd < 0) {
        perror("open");
        return 1;
    }
    if (ioctl(fd, BLKRRPART) < 0) {
        perror("BLKRRPART");
        close(fd);
        return 1;
    }
    close(fd);
    return 0;
}
