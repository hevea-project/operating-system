/*
 * kpt.c — parse the GPT of an NBD disk and expose each partition as a loop
 * device with the right offset, so the initramfs can mount the erofs root
 * without relying on the kernel partition scan (which does not trigger in
 * the netlink NBD_CMD_CONNECT path).
 *
 * For each GPT partition it sets up /dev/loop<N> (N = partition number - 1)
 * bound to the disk with lo_offset/lo_sizelimit, and prints:
 *     loop<N> <partno> <partlabel>
 *
 * Build: aarch64-buildroot-linux-gnu-gcc -O2 -static -o kpt kpt.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <linux/loop.h>

static uint64_t rd64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static uint32_t rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }

static int read_at(int fd, uint64_t off, void *buf, size_t len)
{
    if (lseek(fd, off, SEEK_SET) < 0) return -1;
    uint8_t *p = buf;
    while (len) {
        ssize_t n = read(fd, p, len);
        if (n <= 0) return -1;
        p += n; len -= n;
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: %s /dev/nbdX\n", argv[0]); return 2; }
    int fd = open(argv[1], O_RDWR);
    if (fd < 0) { perror("open disk"); return 1; }

    uint8_t hdr[512];
    if (read_at(fd, 512, hdr, 512) < 0) { perror("read gpt header"); return 1; }
    if (memcmp(hdr, "EFI PART", 8) != 0) {
        fprintf(stderr, "no GPT signature\n");
        return 1;
    }
    uint64_t entry_lba = rd64(hdr + 72);
    uint32_t num_entries = rd32(hdr + 80);
    uint32_t entry_size = rd32(hdr + 84);
    if (entry_size < 128 || num_entries == 0 || num_entries > 128) {
        fprintf(stderr, "bad GPT geometry\n");
        return 1;
    }
    uint8_t *entries = malloc((size_t)entry_size * num_entries);
    if (!entries) return 1;
    if (read_at(fd, entry_lba * 512, entries, (size_t)entry_size * num_entries) < 0) {
        perror("read gpt entries");
        return 1;
    }

    int count = 0;
    for (uint32_t i = 0; i < num_entries; i++) {
        uint8_t *e = entries + (size_t)i * entry_size;
        uint64_t first = rd64(e + 32);
        uint64_t last = rd64(e + 40);
        if (first == 0 && last == 0) continue; /* unused entry */
        char name[37];
        for (int j = 0; j < 36; j++) {
            uint16_t c = e[56 + j * 2] | (e[57 + j * 2] << 8);
            name[j] = (c < 128) ? (char)c : '?';
        }
        name[36] = 0;
        int partno = i + 1;
        int loopno = partno - 1;
        char loopdev[32];
        snprintf(loopdev, sizeof loopdev, "/dev/loop%d", loopno);
        /* create the node if devtmpfs did not */
        struct stat st;
        if (stat(loopdev, &st) < 0)
            mknod(loopdev, S_IFBLK | 0600, makedev(7, loopno));
        int lfd = open(loopdev, O_RDWR);
        if (lfd < 0) { perror("open loop"); continue; }
        if (ioctl(lfd, LOOP_SET_FD, fd) < 0) { perror("LOOP_SET_FD"); close(lfd); continue; }
        struct loop_info64 li;
        memset(&li, 0, sizeof li);
        li.lo_offset = first * 512;
        li.lo_sizelimit = (last - first + 1) * 512;
        if (ioctl(lfd, LOOP_SET_STATUS64, &li) < 0) { perror("LOOP_SET_STATUS64"); ioctl(lfd, LOOP_CLR_FD, 0); close(lfd); continue; }
        close(lfd);
        /* The kernel partition scan does not run for netlink-attached NBD,
         * so /dev/nbd0pN and /dev/disk/by-partlabel/* never appear. Create
         * them ourselves so that rauc (booted-slot detection) and the
         * systemd mount units find the partitions. */
        char link[128], target[32];
        mkdir("/dev/disk", 0755);
        mkdir("/dev/disk/by-partlabel", 0755);
        snprintf(link, sizeof link, "/dev/nbd0p%d", partno);
        snprintf(target, sizeof target, "/dev/loop%d", loopno);
        unlink(link); symlink(target, link);
        snprintf(link, sizeof link, "/dev/disk/by-partlabel/%s", name);
        unlink(link); symlink(target, link);
        printf("loop%d %d %s\n", loopno, partno, name);
        count++;
    }
    free(entries);
    close(fd);
    return count ? 0 : 1;
}
