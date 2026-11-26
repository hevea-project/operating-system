#!/bin/sh
# Builds the diskless-boot initramfs (tftp/initrd.gz) from a HAOS rpi4_64
# build tree.
#
# Usage:
#   ./make-initramfs.sh <output_rpi4_64 dir> [nbd_server_ip] [output_file]
#
# Examples:
#   ./make-initramfs.sh ../../../output_rpi4_64 192.168.1.101            # RPi4 PXE (tftp/initrd.gz)
#   ./make-initramfs.sh ../../../output_rpi4_64 10.0.2.2 /tmp/initrd-qemu.gz  # QEMU raspi4b (slirp: host = 10.0.2.2)
#
# The initramfs contains:
#   - busybox (+ its loader/libs) from the buildroot build
#   - nbd.ko from the built kernel
#   - nbd-connect, a minimal static NBD client (see nbd-connect.c)
#   - /init: DHCP is done by the kernel itself (ip=dhcp, CONFIG_IP_PNP_DHCP=y),
#     then nbd.ko is loaded, the NBD export is attached as /dev/nbd0 and the
#     erofs system partition is mounted and switch_root'ed into.
#     The whole disk image is exported over NBD, so all partitions exist and
#     RAUC A/B updates work exactly as on an SD card (writes go back to the
#     image file on the PC).

set -eu

OUT="${1:?usage: $0 <output_rpi4_64 dir> [nbd_server_ip]}"
SRV_IP="${2:-192.168.1.101}"
SRV_PORT="${NBD_PORT:-10809}"
OUT_FILE="${3:-}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TFTP_DIR="$SCRIPT_DIR/tftp"

CROSS="$OUT/host/bin/aarch64-buildroot-linux-gnu-"
LINUX="$OUT/build/linux-custom"
BUSYBOX_DIR=$(ls -d "$OUT"/build/busybox-* | head -1)

[ -x "${CROSS}gcc" ] || { echo "cross gcc not found: ${CROSS}gcc"; exit 1; }
NBD_KO="$LINUX/drivers/block/nbd.ko"
[ -f "$NBD_KO" ] || NBD_KO=$(find "$LINUX" -name "nbd.ko" -not -path "*/Documentation/*" 2>/dev/null | head -1)
[ -n "$NBD_KO" ] && [ -f "$NBD_KO" ] || { echo "nbd.ko not found in $LINUX (kernel build not finished?)"; exit 1; }
[ -x "$BUSYBOX_DIR/busybox" ] || { echo "busybox not found in $BUSYBOX_DIR"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# NB: the buildroot aarch64 ld.so searches /lib64 (not /lib) by default
mkdir -p "$WORK"/{bin,lib64,modules,proc,sys,dev,newroot}

echo "==> busybox from $BUSYBOX_DIR"
cp "$BUSYBOX_DIR/busybox" "$WORK/bin/busybox"
chmod 755 "$WORK/bin/busybox"

# Loader + shared libs busybox needs. Prefer the target rootfs, fall back to
# the toolchain sysroot, per library.
SYSROOT_LIB="$OUT/host/aarch64-buildroot-linux-gnu/sysroot/lib"
echo "==> libs"
NEEDED=$("${CROSS}readelf" -d "$WORK/bin/busybox" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p')
cp "$OUT/target/lib/ld-linux-aarch64.so.1" "$WORK/lib64/" 2>/dev/null \
    || cp "$SYSROOT_LIB/ld-linux-aarch64.so.1" "$WORK/lib64/"
for l in $NEEDED; do
    if [ -e "$OUT/target/lib/$l" ]; then
        cp "$OUT/target/lib/$l" "$WORK/lib64/"
    else
        cp "$SYSROOT_LIB/$l" "$WORK/lib64/"
    fi
done
# also keep a copy in /lib for good measure (interpreter path is absolute)
cp -a "$WORK/lib64/." "$WORK/lib/" 2>/dev/null || { mkdir -p "$WORK/lib"; cp -a "$WORK/lib64/." "$WORK/lib/"; }
ln -s busybox "$WORK/bin/sh"

echo "==> nbd.ko ($NBD_KO)"
cp "$NBD_KO" "$WORK/modules/nbd.ko"

echo "==> nbd-connect"
if "${CROSS}gcc" -O2 -static -o "$WORK/bin/nbd-connect" "$SCRIPT_DIR/nbd-connect.c" 2>/dev/null; then
    echo "    static build ok"
else
    echo "    static build failed, dynamic build"
    "${CROSS}gcc" -O2 -o "$WORK/bin/nbd-connect" "$SCRIPT_DIR/nbd-connect.c"
fi

echo "==> init"
if [ -n "${INIT_MODE:-}" ] && [ "$INIT_MODE" = "sleep" ]; then
cat > "$WORK/init.sh" <<'EOFSLEEP'
#!/bin/busybox sh
/bin/keeper 2>/dev/null &
/bin/nbd-connect /modules/nbd.ko 192.168.1.37 10809 /dev/nbd0 &
/bin/busybox sleep 100000
EOFSLEEP
else
cat > "$WORK/init.sh" <<EOF
#!/bin/busybox sh
BB=/bin/busybox
/bin/kmount -t proc proc /proc
/bin/kmount -t sysfs sysfs /sys
/bin/kmount -t devtmpfs devtmpfs /dev 2>/dev/null
log() { \$BB echo "init: \$*" > /dev/console 2>/dev/null; \$BB echo "init: \$*" > /dev/kmsg 2>/dev/null; }
log "starting, cmdline=\$(\$BB cat /proc/cmdline)"
# NBD server from kernel cmdline (nbd=IP:PORT), fallback to the compiled-in default
NBD="\$(\$BB grep -o 'nbd=[^ ]*' /proc/cmdline | \$BB cut -d= -f2)"
NBD_IP="\${NBD%%:*}"; NBD_PORT="\${NBD##*:}"
[ -n "\$NBD_IP" ] || NBD_IP="$SRV_IP"
[ -n "\$NBD_PORT" ] || NBD_PORT="$SRV_PORT"
log "nbd target \$NBD_IP:\$NBD_PORT"
# nowdt: do NOT arm the watchdog here; this process dies at switch_root and
# an armed nowayout watchdog would then hard-reset the SoC mid-systemd.
WD_MAGIC_CLOSE=1 /bin/keeper $SRV_IP 6667 &
# netlink attach: the kernel serves /dev/nbd0 itself, no persistent
# NBD_DO_IT task (which systemd's initramfs cleanup would kill ~6s after
# switch_root and tear the connection down).
NBD_NETLINK=1 /bin/nbd-connect /modules/nbd.ko \$NBD_IP \$NBD_PORT /dev/nbd0 &
n=0
while [ \$n -lt 100 ]; do
    # wait until the kernel has set the device capacity (nbd_set_size),
    # otherwise early reads return zeros and the GPT parse fails
    sz=\$(\$BB cat /sys/block/nbd0/size 2>/dev/null)
    [ -n "\$sz" ] && [ "\$sz" -gt 0 ] && break
    \$BB sleep 0.1
    n=\$((n+1))
done
log "nbd0: \$(\$BB ls -la /dev/nbd0 2>&1)"
log "ip: \$(\$BB ip -4 addr show 2>/dev/null | \$BB grep inet)"
# The kernel partition scan does not trigger on the netlink NBD_CMD_CONNECT
# path, so expose each GPT partition as a loop device with the right offset
# (kpt reads the GPT from /dev/nbd0 itself).
/bin/kpt /dev/nbd0 > /dev/kmsg 2>&1 || log "kpt rc=\$?"
ROOTDEV=""
i=0
while [ \$i -lt 16 ]; do
    p=/dev/loop\$i
    [ -b "\$p" ] || { i=\$((i+1)); continue; }
    if /bin/kmount -t erofs -o ro "\$p" /newroot 2>/dev/null; then
        ROOTDEV="\$p"
        break
    fi
    log "nomount \$p"
    i=\$((i+1))
done
if [ -z "\$ROOTDEV" ]; then
    log "ERROR: no erofs root found on /dev/nbd0"
    exec /bin/busybox sh
fi
log "diskless: root on \$ROOTDEV (nbd)"
# Bind-mount the repo's haos-expand over the image's: the image may predate
# the loop-backed (diskless) fix in buildroot-external.
if [ -f /haos-expand ]; then
    /bin/kmount -o bind /haos-expand /newroot/usr/libexec/haos-expand 2>/dev/null \\
        || log "bind haos-expand failed"
fi
/bin/kmount -o move /proc /newroot/proc
/bin/kmount -o move /sys /newroot/sys
/bin/kmount -o move /dev /newroot/dev
exec \$BB switch_root /newroot /sbin/init
EOF
fi
chmod 755 "$WORK/init.sh"

# repo version of haos-expand (bind-mounted over the image's at boot, see init)
cp "$SCRIPT_DIR/../../../buildroot-external/rootfs-overlay/usr/libexec/haos-expand" "$WORK/haos-expand" 2>/dev/null || true

echo "==> init wrapper + kmount (static C)"
"${CROSS}gcc" -O2 -static -o "$WORK/init" "$SCRIPT_DIR/init-wrapper.c"
"${CROSS}gcc" -O2 -static -o "$WORK/bin/kmount" "$SCRIPT_DIR/kmount.c"
"${CROSS}gcc" -O2 -static -o "$WORK/bin/keeper" "$SCRIPT_DIR/keeper.c"
"${CROSS}gcc" -O2 -static -o "$WORK/bin/kpart" "$SCRIPT_DIR/kpart.c"
"${CROSS}gcc" -O2 -static -o "$WORK/bin/kpt" "$SCRIPT_DIR/kpt.c"

[ -n "$OUT_FILE" ] || OUT_FILE="$TFTP_DIR/initrd.gz"
mkdir -p "$(dirname "$OUT_FILE")"
echo "==> packing $OUT_FILE"
(cd "$WORK" && find . | cpio -o -H newc --quiet | gzip -9) > "$OUT_FILE"

echo "==> Done: $OUT_FILE ($(du -h "$OUT_FILE" | cut -f1))"
echo "    NBD server expected at $SRV_IP:$SRV_PORT"
