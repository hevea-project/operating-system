/*
 * wdog-pet.c — keep the BCM2835 hardware watchdog alive during the slow
 * NBD boot: open /dev/watchdog and write to it every second, forever.
 * Started in the background by init.sh; survives switch_root.
 *
 * Build: aarch64-buildroot-linux-gnu-gcc -O2 -static -o wdog-pet wdog-pet.c
 */
#include <fcntl.h>
#include <unistd.h>
#include <fcntl.h>

int main(void)
{
    int fd = open("/dev/watchdog0", O_WRONLY);
    if (fd < 0)
        fd = open("/dev/watchdog", O_WRONLY);
    if (fd < 0)
        return 1;
    { int km = open("/dev/kmsg", O_WRONLY); if (km >= 0) { write(km, "wdog-pet: petting\n", 18); close(km); } }
    for (;;) {
        write(fd, "1", 1);
        usleep(200000);
    }
}
