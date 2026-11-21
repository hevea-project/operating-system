#!/bin/sh
# Extracts PXE boot files from a HAOS RPi4 disk image (.img).
#
# Usage:
#   sudo ./extract-boot-files.sh /path/to/haos_rpi4-18.4.img
#
# Output:
#   tftp/  — kernel8.img, *.dtb, overlays/, config.txt, cmdline.txt (TFTP)
#   http/  — hassos-system0.erofs + hassos-kernel0 (HTTP, for an initramfs
#            that loop-mounts the erofs rootfs over the network)
#
# NOTE: the stock HAOS cmdline.txt boots with root=PARTUUID=... rootfstype=erofs,
# i.e. it expects the SD card. A full diskless boot therefore needs a custom
# initramfs that downloads the erofs image over HTTP and loop-mounts it.
# Until then, use the PXE server to smoke-test network boot (DHCP/TFTP/kernel
# load) and use SD boot + HA power switch (hevea-rpi-strategy.yaml) for the
# full test suite.

set -eu

IMG="${1:?usage: $0 <haos_rpi4.img>}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TFTP_DIR="$SCRIPT_DIR/tftp"
HTTP_DIR="$SCRIPT_DIR/http"

echo "==> Mounting $IMG"
LOOPDEV=$(losetup --show -f -P "$IMG")
cleanup() {
    losetup -d "$LOOPDEV" 2>/dev/null || true
    umount /mnt/haos-boot /mnt/haos-system0 2>/dev/null || true
}
trap cleanup EXIT

# Find partitions by PARTLABEL instead of assuming fixed numbers
BOOT_PART=$(lsblk -n -o NAME,PARTLABEL "$LOOPDEV" | awk '$2=="hassos-boot"{print "/dev/"$1}')
SYSTEM0_PART=$(lsblk -n -o NAME,PARTLABEL "$LOOPDEV" | awk '$2=="hassos-system0"{print "/dev/"$1}')
echo "    boot=$BOOT_PART system0=$SYSTEM0_PART"
[ -n "$BOOT_PART" ] || { echo "hassos-boot partition not found"; exit 1; }

mkdir -p /mnt/haos-boot /mnt/haos-system0
mount "$BOOT_PART" /mnt/haos-boot

echo "==> Copying boot files to $TFTP_DIR"
mkdir -p "$TFTP_DIR/overlays"
cp /mnt/haos-boot/kernel8.img "$TFTP_DIR/" 2>/dev/null || cp /mnt/haos-boot/kernel.img "$TFTP_DIR/kernel8.img"
cp /mnt/haos-boot/*.dtb "$TFTP_DIR/" 2>/dev/null || true
cp -r /mnt/haos-boot/overlays/* "$TFTP_DIR/overlays/" 2>/dev/null || true
cp /mnt/haos-boot/cmdline.txt "$TFTP_DIR/"
cp /mnt/haos-boot/config.txt "$TFTP_DIR/"
umount /mnt/haos-boot

echo "==> Copying erofs system image to $HTTP_DIR (for a diskless initramfs)"
mkdir -p "$HTTP_DIR"
if [ -n "$SYSTEM0_PART" ]; then
    dd if="$SYSTEM0_PART" of="$HTTP_DIR/hassos-system0.erofs" bs=4M status=none
else
    echo "    hassos-system0 not found, skipping"
fi

cleanup
trap - EXIT

echo "==> Done. Boot files in $TFTP_DIR, erofs in $HTTP_DIR"
echo "    Start the PXE server: cd $SCRIPT_DIR && docker compose up -d"
echo "    NOTE: stock cmdline.txt still points at root=PARTUUID (SD card)."
echo "    Full diskless HAOS boot needs an initramfs that fetches"
echo "    http://<server>/hassos-system0.erofs and loop-mounts it."
