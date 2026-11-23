/*
 * init-wrapper.c — static /init for the diskless-boot initramfs.
 *
 * The kernel runs /init directly; a shell-script shebang proved unreliable
 * here, so /init is this small static binary: it mounts proc/sys/devtmpfs,
 * redirects stdio to /dev/console (so logs also reach netconsole) and
 * execs the real script /init.sh with busybox sh.
 *
 * Build (cross, from the HAOS build tree):
 *   aarch64-buildroot-linux-gnu-gcc -O2 -static -o init init-wrapper.c
 */
#include <fcntl.h>
#include <unistd.h>
#include <sys/mount.h>

int main(void)
{
    mount("proc", "/proc", "proc", 0, NULL);
    mount("sysfs", "/sys", "sysfs", 0, NULL);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);

    int fd = open("/dev/console", O_RDWR);
    if (fd >= 0) {
        dup2(fd, 0);
        dup2(fd, 1);
        dup2(fd, 2);
    }
    int km = open("/dev/kmsg", O_WRONLY);
    if (km >= 0) {
        write(km, "init-wrapper: starting /init.sh\n", 33);
        close(km);
    }


    char *argv[] = {"/bin/busybox", "sh", "/init.sh", NULL};
    char *envp[] = {"PATH=/bin", NULL};
    execve("/bin/busybox", argv, envp);
    return 127;
}
