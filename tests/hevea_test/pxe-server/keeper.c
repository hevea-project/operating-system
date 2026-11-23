/*
 * keeper.c — initramfs background keeper for the slow NBD boot:
 *   - pets the BCM2835 hardware watchdog (/dev/watchdog0) every 200 ms
 *   - forwards kernel log lines (/dev/kmsg) to a UDP beacon on the PC
 *     (port 6667) using a regular socket, so logs survive netconsole's
 *     netpoll carrier loss when networkd reconfigures eth0.
 *
 * The PC side captures with: tcpdump -i any -nn -A 'udp port 6667'
 *
 * Build: aarch64-buildroot-linux-gnu-gcc -O2 -static -o keeper keeper.c
 */
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <arpa/inet.h>
#include <sys/socket.h>

int main(int argc, char **argv)
{
    const char *server = (argc > 1) ? argv[1] : "192.168.1.37";
    int port = (argc > 2) ? atoi(argv[2]) : 6667;
    /* "nowdt": do not open the watchdog. Opening /dev/watchdog ARMS the
     * BCM2835 watchdog; with nowayout it cannot be stopped again, so when
     * this process is killed by switch_root the SoC hard-resets a watchdog
     * period later. Pass nowdt for the real (switch_root) boot. */
    int nowdt = (argc > 3 && strcmp(argv[3], "nowdt") == 0);

    int wd = -1;
    int wd2 = -1;
    if (!nowdt) {
        wd = open("/dev/watchdog0", O_WRONLY);
        if (wd < 0)
            wd = open("/dev/watchdog", O_WRONLY);
        if (wd >= 0 && getenv("WD_MAGIC_CLOSE")) {
            /* nowayout=0: stop the watchdog for good */
            if (write(wd, "V", 1) == 1) {
                int k2 = open("/dev/kmsg", O_WRONLY);
                if (k2 >= 0) { write(k2, "keeper: watchdog magic-closed\n", 31); close(k2); }
            }
            close(wd);
            wd = -1;
        }
    }

    int km = open("/dev/kmsg", O_RDONLY | O_NONBLOCK);

    /* debug: dump watchdog state */
    {
        const char *attrs[] = {"timeout", "nowayout", "bootstatus", "state", "pretimeout", NULL};
        const char *devs[] = {"watchdog0", "watchdog1", NULL};
        for (int d = 0; devs[d]; d++)
        for (int i = 0; attrs[i]; i++) {
            char path[128], b[128];
            snprintf(path, sizeof path, "/sys/class/watchdog/%s/%s", devs[d], attrs[i]);
            int f = open(path, O_RDONLY);
            if (f >= 0) {
                ssize_t n = read(f, b, sizeof b - 1);
                close(f);
                if (n > 0) {
                    b[n] = 0;
                    char m[192];
                    snprintf(m, sizeof m, "wdt %s %s=%s", devs[d], attrs[i], b);
                    int k2 = open("/dev/kmsg", O_WRONLY);
                    if (k2 >= 0) { write(k2, "keeper: ", 8); write(k2, m, strlen(m)); write(k2, "\n", 1); close(k2); }
                }
            }
        }
    }

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    inet_pton(AF_INET, server, &sa.sin_addr);

    char buf[2048];
    int beats = 0;
    for (;;) {
        if (wd >= 0)
            write(wd, "1", 1);
        if (++beats % 5 == 0) {
            /* every ~1s: re-scan for watchdog devices that appear later
             * (e.g. the bcm2835-pm watchdog once the GPU driver loads) and
             * pet them too */
            if (wd2 < 0) {
                wd2 = open("/dev/watchdog1", O_WRONLY);
                if (wd2 >= 0) {
                    int k2 = open("/dev/kmsg", O_WRONLY);
                    if (k2 >= 0) { write(k2, "keeper: petting watchdog1 too\n", 30); close(k2); }
                }
            }
            if (wd2 >= 0)
                write(wd2, "1", 1);
        }
        if (++beats % 25 == 0) /* every ~5s: UDP heartbeat, survives kmsg issues */
            sendto(fd, "keeper: alive\n", 14, 0, (struct sockaddr *)&sa, sizeof(sa));
        if (km >= 0) {
            ssize_t n;
            while ((n = read(km, buf, sizeof(buf) - 1)) > 0) {
                buf[n] = 0;
                sendto(fd, buf, n, 0, (struct sockaddr *)&sa, sizeof(sa));
            }
        }
        usleep(200000);
    }
}
