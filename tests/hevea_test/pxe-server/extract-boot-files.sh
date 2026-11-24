#!/bin/sh
# Extracts PXE/NBD boot files from a HAOS RPi4 disk image (.img or .img.xz).
#
# Usage:
#   ./extract-boot-files.sh /path/to/hevea_rpi4-64-18.4.1.img[.xz]
#
# Output:
#   tftp/  — boot partition contents (start4.elf, *.dtb, overlays/, Image,
#            config.txt, cmdline.txt) + diskless overrides + initrd.gz target
#   nbd/   — reflink/sparse copy of the raw disk image, exported over NBD
#            (port 10809) so the RPi4 boots fully diskless with the whole
#            disk as a block device (RAUC A/B updates included). The
#            hassos-data partition is grown to fill the image (default 8G,
#            --no-grow to skip) — haos-expand resizes the ext4 at boot.
#   http/  — hassos-system0.erofs (debug/reference only)
#
# No root needed: partitions are located with `sfdisk -d` and the vfat boot
# partition is extracted with mtools (`dnf install mtools`). The erofs
# partition is copied out with dd. If mtools is missing and we are root,
# falls back to losetup+mount.
#
# The stock HAOS config.txt boots u-boot (which loads the kernel "Image" from
# the hassos-kernel0/1 squashfs partitions) and cmdline.txt points at the SD
# card. For the diskless PXE boot this script:
#   - installs the RAW kernel as tftp/Image (from the build tree, or extracted
#     from the hassos-kernel0 squashfs partition with 7z)
#   - appends "kernel=Image" + "initramfs initrd.gz followkernel" to
#     tftp/config.txt (original kept as config.txt.haos) so the ROM loads the
#     kernel directly over TFTP, bypassing u-boot
#   - writes a diskless tftp/cmdline.txt (ip=dhcp, root on /dev/nbd0p*)
# Run ./make-initramfs.sh <output_rpi4_64 dir> afterwards to build initrd.gz.

set -eu

GROW_DATA=true
GROW_SIZE="8G"
IMG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-grow)   GROW_DATA=false; shift ;;
        --grow-data) GROW_DATA=true; GROW_SIZE="${2:?--grow-data needs a size, e.g. 8G}"; shift 2 ;;
        -h|--help)   sed -n '2,25p' "$0"; exit 0 ;;
        *)           IMG="$1"; shift ;;
    esac
done
IMG="${IMG:?usage: $0 [--no-grow|--grow-data SIZE] <hevea_rpi4.img[.xz]>}"
case "$IMG" in
    *.xz) [ -f "${IMG%.xz}" ] || unxz -k "$IMG"; IMG="${IMG%.xz}" ;;
esac

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TFTP_DIR="$SCRIPT_DIR/tftp"
HTTP_DIR="$SCRIPT_DIR/http"
NBD_DIR="$SCRIPT_DIR/nbd"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- locate partitions by name via sfdisk -d ---
# lines look like: <img>1 : start= 2048, size= 65536, ..., name="hassos-boot"
part_start() { sfdisk -d "$IMG" | awk -v n="\"$1\"" '$0 ~ n { for (i=1;i<=NF;i++) if ($i=="start=") { gsub(",","",$(i+1)); print $(i+1) } }'; }
part_size()  { sfdisk -d "$IMG" | awk -v n="\"$1\"" '$0 ~ n { for (i=1;i<=NF;i++) if ($i=="size=")  { gsub(",","",$(i+1)); print $(i+1) } }'; }

BOOT_START=$(part_start hassos-boot);  BOOT_SIZE=$(part_size hassos-boot)
SYS0_START=$(part_start hassos-system0); SYS0_SIZE=$(part_size hassos-system0)
[ -n "$BOOT_START" ] || { echo "hassos-boot partition not found in $IMG"; exit 1; }
echo "==> hassos-boot: start=$BOOT_START size=$BOOT_SIZE.. (sectors of 512B)"
[ -n "$SYS0_START" ] && echo "    hassos-system0: start=$SYS0_START size=$SYS0_SIZE"

echo "==> Extracting boot partition to $TFTP_DIR"
# Wipe the previous content first: stale files (e.g. an old kernel Image)
# would otherwise mask files missing from the new image.
mkdir -p "$TFTP_DIR"
find "$TFTP_DIR" -mindepth 1 -delete
dd if="$IMG" of="$WORK/boot.part" bs=512 skip="$BOOT_START" count="$BOOT_SIZE" status=none
if command -v mcopy >/dev/null 2>&1; then
    mcopy -s -o -i "$WORK/boot.part" ::/ "$TFTP_DIR/"
elif [ "$(id -u)" = "0" ]; then
    LOOPDEV=$(losetup --show -f "$WORK/boot.part")
    mkdir -p /mnt/haos-boot
    mount "$LOOPDEV" /mnt/haos-boot
    cp -a /mnt/haos-boot/. "$TFTP_DIR/"
    umount /mnt/haos-boot; losetup -d "$LOOPDEV"
else
    echo "need mtools (dnf install mtools) or run as root"; exit 1
fi

echo "==> Kernel Image -> $TFTP_DIR/Image"
# The boot partition does NOT contain the kernel: u-boot's boot.scr loads it
# as file "Image" from the hassos-kernel0/1 squashfs partitions. With the
# diskless override (kernel=Image in config.txt) the ROM loads tftp/Image
# directly, so we must provide the RAW kernel there.
IMG_DIR=$(CDPATH= cd -- "$(dirname "$IMG")" && pwd)
LINUX_IMAGE="$IMG_DIR/../build/linux-custom/arch/arm64/boot/Image"
if [ -f "$LINUX_IMAGE" ]; then
    # build tree present (image from output_<board>/images/): raw kernel
    cp --sparse=always "$LINUX_IMAGE" "$TFTP_DIR/Image"
elif command -v 7z >/dev/null 2>&1; then
    # standalone image: pull Image out of the hassos-kernel0 squashfs (fallback: kernel1)
    for part in hassos-kernel0 hassos-kernel1; do
        K_START=$(part_start "$part"); K_SIZE=$(part_size "$part")
        [ -n "$K_START" ] || continue
        dd if="$IMG" of="$WORK/kernel.squash" bs=512 skip="$K_START" count="$K_SIZE" status=none
        if 7z x -so "$WORK/kernel.squash" Image > "$TFTP_DIR/Image" 2>/dev/null && [ -s "$TFTP_DIR/Image" ]; then
            echo "    extracted from $part (squashfs)"
            break
        fi
    done
fi
if [ ! -s "$TFTP_DIR/Image" ]; then
    echo "ERROR: could not obtain the raw kernel Image (no build tree next to the image and no 7z)" >&2
    exit 1
fi
head -c 2 "$TFTP_DIR/Image" | grep -q "MZ" || echo "WARNING: tftp/Image does not start with the MZ kernel magic"
ls -la "$TFTP_DIR/Image"

echo "==> Diskless PXE overrides in $TFTP_DIR"
# Keep the original config.txt, then force direct kernel boot (no u-boot,
# which would look for the kernel on the SD card) + initramfs.
cp "$TFTP_DIR/config.txt" "$TFTP_DIR/config.txt.haos"
cat >> "$TFTP_DIR/config.txt" <<'EOF'

# --- diskless PXE test overrides (added by extract-boot-files.sh) ---
kernel=Image
initramfs initrd.gz followkernel
EOF
# Stock cmdline expects the SD card. The initramfs does DHCP itself
# (kernel ip=dhcp), attaches the NBD-exported whole disk as /dev/nbd0 and
# mounts the erofs system partition from it. The NBD server address is
# templated (@NBD_SERVER@/@NBD_PORT@) and filled in by entrypoint.sh with
# the detected IP of the PC's wired interface.
# Mirror u-boot's bootargs_haos from boot.scr: without zram.num_devices=3 the
# built-in zram only creates zram0, so /dev/zram1 (var) and /dev/zram2 (tmp)
# never appear, zram-var/zram-tmp fail and /tmp + /var stay on the read-only
# erofs root (docker then fails with "mkdir /tmp/...: read-only file system").
cat > "$TFTP_DIR/cmdline.txt.in" <<'EOF'
ip=dhcp nbd=@NBD_SERVER@:@NBD_PORT@ root=/dev/nbd0p3 rootfstype=erofs ro rootwait zram.enabled=1 zram.num_devices=3 cgroup_enable=memory fsck.repair=yes console=tty1 console=ttyAMA0,115200
EOF
cp "$TFTP_DIR/cmdline.txt.in" "$TFTP_DIR/cmdline.txt"
chmod -R a+rX "$TFTP_DIR"

echo "==> erofs system0 -> $HTTP_DIR (debug only)"
if [ -n "$SYS0_START" ]; then
    mkdir -p "$HTTP_DIR"
    dd if="$IMG" of="$HTTP_DIR/hassos-system0.erofs" bs=512 skip="$SYS0_START" count="$SYS0_SIZE" status=none
fi

echo "==> Reflink/sparse copy of the disk image for the NBD export -> $NBD_DIR"
mkdir -p "$NBD_DIR"
cp --reflink=auto --sparse=always "$IMG" "$NBD_DIR/hevea_rpi4.img"
chmod a+r "$NBD_DIR/hevea_rpi4.img"
if [ "$GROW_DATA" = true ]; then
    echo "==> Growing hassos-data partition of the NBD copy to fill ${GROW_SIZE}"
    "$SCRIPT_DIR/grow-data-partition.sh" "$NBD_DIR/hevea_rpi4.img" "$GROW_SIZE"
fi

echo "==> Done. Boot files in $TFTP_DIR, image copy in $NBD_DIR, erofs in $HTTP_DIR"
echo "    Build the initramfs: ./make-initramfs.sh ../../../output_rpi4_64"
echo "    Start the PXE+NBD server: cd $SCRIPT_DIR && docker compose down && docker compose up -d"
echo "    Boot the RPi4 with no SD card: it netboots and mounts the whole disk"
echo "    image over NBD (qemu-nbd on port 10809) as its root device."
