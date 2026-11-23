/*
 * nbd-connect.c — minimal NBD client for the diskless-boot initramfs.
 *
 * Loads the nbd kernel module (the HAOS busybox has no insmod applet),
 * performs a fixed-newstyle NBD handshake (NBD_OPT_EXPORT_NAME) over TCP,
 * attaches the socket to a /dev/nbdX device and then blocks in NBD_DO_IT
 * so the kernel serves block I/O on that device. Run it in the background:
 *
 *   nbd-connect <nbd.ko> <server-ip> <port> /dev/nbd0 &
 *
 * The process must stay alive for the block device to keep working.
 *
 * Build (cross, from the HAOS build tree):
 *   aarch64-buildroot-linux-gnu-gcc -O2 -static -o nbd-connect nbd-connect.c
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <signal.h>
#include <linux/nbd.h>

static void die(const char *msg);
static void klog(const char *msg);

static void sig_handler(int sig)
{
    char b[64];
    snprintf(b, sizeof b, "GOT SIGNAL %d", sig);
    klog(b);
    _exit(128 + sig);
}

static void klog(const char *msg)
{
    int fd = open("/dev/kmsg", O_WRONLY);
    if (fd >= 0) {
        write(fd, "nbd-connect: ", 13);
        write(fd, msg, strlen(msg));
        write(fd, "\n", 1);
        close(fd);
    }
}


static void load_module(const char *path)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        die("open module");
    if (syscall(SYS_finit_module, fd, "", 0) < 0 && errno != EEXIST && errno != EPERM)
        die("finit_module");
    close(fd);
}

#define NBD_MAGIC       0x4e42444d41474943ULL /* "NBDMAGIC" */
#define IHAVEOPT        0x49484156454F5054ULL /* "IHAVEOPT" */
#define NBD_OPT_EXPORT_NAME 1
#define CLIENT_FLAG_FIXED_NEWSTATE 1

/* ---- generic netlink NBD_CMD_CONNECT (kernel serves I/O, no persistent
 * userspace task needed — survives systemd killing initramfs leftovers) ---- */
#include <linux/netlink.h>
#include <linux/genetlink.h>
#include <linux/nbd-netlink.h>
#include <sys/socket.h>

/* old buildroot kernel headers lack the netlink inline helpers */
#ifndef NLA_F_NESTED
#define NLA_F_NESTED (1 << 15)
#endif
#ifndef nla_ok
static inline int nla_ok(const struct nlattr *nla, int rem)
{
    return rem >= (int)sizeof(*nla) && nla->nla_len >= sizeof(*nla) &&
           nla->nla_len <= rem;
}
static inline struct nlattr *nla_next(const struct nlattr *nla, int *rem)
{
    int tot = NLA_ALIGN(nla->nla_len);
    *rem -= tot;
    return (struct nlattr *)((char *)nla + tot);
}
static inline uint16_t nla_get_u16(const struct nlattr *nla)
{
    uint16_t v;
    memcpy(&v, (char *)nla + NLA_HDRLEN, sizeof v);
    return v;
}
#endif

static void nla_put(struct msghdr *msg, int type, const void *data, int len)
{
    struct nlattr *nla = (struct nlattr *)((char *)msg->msg_iov->iov_base + msg->msg_iov->iov_len);
    int pad = NLA_ALIGN(len);
    nla->nla_type = type;
    nla->nla_len = NLA_HDRLEN + len;
    memcpy((char *)nla + NLA_HDRLEN, data, len);
    msg->msg_iov->iov_len += NLA_ALIGN(nla->nla_len);
}
static void nla_put_nested_start(struct msghdr *msg, int type, void **hdr)
{
    struct nlattr *nla = (struct nlattr *)((char *)msg->msg_iov->iov_base + msg->msg_iov->iov_len);
    nla->nla_type = NLA_F_NESTED | type;
    nla->nla_len = NLA_HDRLEN;
    msg->msg_iov->iov_len += NLA_HDRLEN;
    *hdr = nla;
}
static void nla_put_nested_end(struct msghdr *msg, void *hdr)
{
    ((struct nlattr *)hdr)->nla_len = (char *)msg->msg_iov->iov_base + msg->msg_iov->iov_len - (char *)hdr;
}

static int genl_family_id(int fd, const char *name)
{
    char buf[4096];
    struct iovec iov = { buf, sizeof buf };
    struct msghdr msg = { NULL, 0, &iov, 1, NULL, 0, 0 };
    struct nlmsghdr *nl = (struct nlmsghdr *)buf;
    struct genlmsghdr *gh = (struct genlmsghdr *)(nl + 1);
    nl->nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
    nl->nlmsg_type = GENL_ID_CTRL;
    nl->nlmsg_flags = NLM_F_REQUEST;
    gh->cmd = CTRL_CMD_GETFAMILY;
    gh->version = 2;
    msg.msg_iov->iov_len = nl->nlmsg_len;
    char namebuf[64];
    snprintf(namebuf, sizeof namebuf, "%s", name);
    nla_put(&msg, CTRL_ATTR_FAMILY_NAME, namebuf, strlen(namebuf) + 1);
    nl->nlmsg_len = msg.msg_iov->iov_len;
    if (sendmsg(fd, &msg, 0) < 0)
        die("genl getfamily send");
    iov.iov_len = sizeof buf;
    if (recvmsg(fd, &msg, 0) < 0)
        die("genl getfamily recv");
    nl = (struct nlmsghdr *)buf;
    gh = (struct genlmsghdr *)(nl + 1);
    struct nlattr *attr = (struct nlattr *)((char *)gh + GENL_HDRLEN);
    int rem = nl->nlmsg_len - NLMSG_LENGTH(GENL_HDRLEN);
    while (nla_ok(attr, rem)) {
        if (attr->nla_type == CTRL_ATTR_FAMILY_ID)
            return nla_get_u16(attr);
        attr = nla_next(attr, &rem);
    }
    die("family id not found");
    return -1;
}

/* Hand the connected+negotiated socket to the kernel via NBD_CMD_CONNECT. */
static void netlink_attach(int nlfd, int family, int tcp_fd, uint64_t size, int index)
{
    char buf[4096];
    struct iovec iov = { buf, sizeof buf };
    struct msghdr msg = { NULL, 0, &iov, 1, NULL, 0, 0 };
    struct nlmsghdr *nl = (struct nlmsghdr *)buf;
    struct genlmsghdr *gh = (struct genlmsghdr *)(nl + 1);
    nl->nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
    nl->nlmsg_type = family;
    nl->nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
    gh->cmd = NBD_CMD_CONNECT;
    gh->version = 0; /* same as nbd-client */
    msg.msg_iov->iov_len = nl->nlmsg_len;
    uint32_t idx = index;
    nla_put(&msg, NBD_ATTR_INDEX, &idx, sizeof idx);
    nla_put(&msg, NBD_ATTR_SIZE_BYTES, &size, sizeof size);
    void *sockets, *item;
    nla_put_nested_start(&msg, NBD_ATTR_SOCKETS, &sockets);
    nla_put_nested_start(&msg, NBD_SOCK_ITEM, &item);
    uint32_t fdnum = tcp_fd;
    nla_put(&msg, NBD_SOCK_FD, &fdnum, sizeof fdnum);
    nla_put_nested_end(&msg, item);
    nla_put_nested_end(&msg, sockets);
    nl->nlmsg_len = msg.msg_iov->iov_len;
    /* NB: no SCM_RIGHTS — genl is processed synchronously in the sender's
     * context, so the kernel resolves the fd in our own fd table. */
    if (sendmsg(nlfd, &msg, 0) < 0)
        die("NBD_CMD_CONNECT send");
    /* read ACK */
    iov.iov_len = sizeof buf;
    if (recvmsg(nlfd, &msg, 0) < 0)
        die("NBD_CMD_CONNECT recv");
    nl = (struct nlmsghdr *)buf;
    if (nl->nlmsg_type == NLMSG_ERROR) {
        struct nlmsgerr *e = (struct nlmsgerr *)(nl + 1);
        if (e->error != 0) {
            errno = -e->error;
            die("NBD_CMD_CONNECT ack");
        }
    }
}

static void die(const char *msg)
{
    char b[160];
    snprintf(b, sizeof b, "FATAL %s: %s", msg, strerror(errno));
    klog(b);
    fprintf(stderr, "nbd-connect: %s: %s\n", msg, strerror(errno));
    exit(1);
}

static void read_full(int fd, void *buf, size_t len)
{
    uint8_t *p = buf;
    while (len > 0) {
        ssize_t n = read(fd, p, len);
        if (n <= 0)
            die("short read during handshake");
        p += n;
        len -= n;
    }
}

static void write_full(int fd, const void *buf, size_t len)
{
    const uint8_t *p = buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n <= 0)
            die("short write during handshake");
        p += n;
        len -= n;
    }
}

static uint64_t read_be64(int fd)
{
    uint64_t v;
    read_full(fd, &v, 8);
    return be64toh(v);
}

int main(int argc, char **argv)
{
    struct sigaction ssa;
    memset(&ssa, 0, sizeof ssa);
    ssa.sa_handler = sig_handler;
    sigaction(SIGTERM, &ssa, NULL);
    sigaction(SIGINT, &ssa, NULL);
    sigaction(SIGHUP, &ssa, NULL);
    sigaction(SIGUSR1, &ssa, NULL);
    sigaction(SIGUSR2, &ssa, NULL);
    sigaction(SIGPIPE, &ssa, NULL);
    if (argc < 5) {
        fprintf(stderr, "usage: %s <nbd.ko> <server-ip> <port> <nbd-device> [export-name]\n", argv[0]);
        return 2;
    }
    load_module(argv[1]);
    klog("module loaded");
    const char *host = argv[2];
    int port = atoi(argv[3]);
    const char *dev = argv[4];

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    if (inet_pton(AF_INET, host, &sa.sin_addr) != 1)
        die("bad server IP");

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        die("socket");
    struct timeval tv = {10, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0)
        die("connect");
    klog("connected");

    /* --- newstyle handshake --- */
    uint64_t magic = read_be64(fd);
    if (magic != NBD_MAGIC)
        die("bad NBDMAGIC");
    uint64_t opt = read_be64(fd);
    if (opt != IHAVEOPT)
        die("server does not speak newstyle");
    uint8_t sflags[2];
    read_full(fd, sflags, 2);

    uint32_t cflags = htonl(CLIENT_FLAG_FIXED_NEWSTATE);
    write_full(fd, &cflags, 4);

    /* NBD_OPT_EXPORT_NAME */
    const char *name = (argc > 5) ? argv[5] : "";
    uint64_t o = htobe64(IHAVEOPT);
    uint32_t op = htonl(NBD_OPT_EXPORT_NAME);
    uint32_t len = htonl(strlen(name));
    write_full(fd, &o, 8);
    write_full(fd, &op, 4);
    write_full(fd, &len, 4);
    write_full(fd, name, strlen(name));

    uint64_t size = read_be64(fd);
    uint8_t tflags[2];
    read_full(fd, tflags, 2);
    uint8_t zeros[124];
    read_full(fd, zeros, sizeof(zeros)); /* fixed newstyle, no NO_ZEROES */
    { char b[96]; snprintf(b, sizeof b, "export size %llu bytes", (unsigned long long)size); klog(b); }

    /* Clear the handshake timeouts: the kernel nbd recv path honors
     * sk_rcvtimeo, and a boot-time pause in NBD traffic would kill the
     * connection. Must happen before the socket is handed to the kernel. */
    struct timeval ztv = {0, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &ztv, sizeof(ztv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &ztv, sizeof(ztv));

    /* netlink attach: the kernel takes over the socket and serves I/O by
     * itself; no persistent userspace task holding NBD_DO_IT is needed, so
     * the connection survives systemd cleaning up initramfs processes. */
    if (getenv("NBD_NETLINK")) {
        int nlfd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
        if (nlfd < 0)
            die("netlink socket");
        int family = genl_family_id(nlfd, "nbd");
        { char b[64]; snprintf(b, sizeof b, "nbd genl family=%d", family); klog(b); }
        int index = 0;
        if (getenv("NBD_INDEX"))
            index = atoi(getenv("NBD_INDEX"));
        netlink_attach(nlfd, family, fd, size, index);
        klog("NBD_CMD_CONNECT ok, kernel serving /dev/nbd0");
        return 0;
    }

    /* --- legacy ioctl attach (NBD_DO_IT blocks in this process) --- */
    int nbd = open(dev, O_RDWR);
    if (nbd < 0)
        die("open nbd device");
    if (ioctl(nbd, NBD_SET_SOCK, fd) < 0)
        die("NBD_SET_SOCK");
    klog("NBD_SET_SOCK ok");
    if (ioctl(nbd, NBD_SET_SIZE, size) < 0)
        die("NBD_SET_SIZE");
    klog("NBD_SET_SIZE ok");
    if (ioctl(nbd, NBD_SET_BLKSIZE, 512) < 0)
        die("NBD_SET_BLKSIZE");
    klog("NBD_SET_BLKSIZE ok");

    /* Blocks: the kernel now serves I/O on the socket. */
    klog("starting NBD_DO_IT");
    if (ioctl(nbd, NBD_DO_IT) < 0) {
        char b[64];
        snprintf(b, sizeof b, "NBD_DO_IT returned errno=%d", errno);
        klog(b);
        die("NBD_DO_IT");
    }
    klog("NBD_DO_IT returned OK");

    ioctl(nbd, NBD_CLEAR_SOCK);
    return 0;
}
