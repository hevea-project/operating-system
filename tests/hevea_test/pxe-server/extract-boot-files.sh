#!/bin/sh
# Extracts PXE boot files from a HAOS RPi4 disk image (.img).
#
# Usage:
#   sudo ./extract-boot-files.sh /path/to/haos_rpi4-18.4.img
#
# Output:
#   tftp/  — kernel, dtbs, cmdline.txt, config.txt (served via TFTP)
#   http/  — rootfs (served via HTTP, referenced from cmdline.txt)
#
# The RPi4 boot ROM loads kernel8.img + dtbs + cmdline.txt via TFTP,
# then the kernel mounts the rootfs from the HTTP URL in cmdline.txt.

set -eu

IMG="${1:?usage: $0 <haos_rpi4.img>}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TFTP_DIR="$SCRIPT_DIR/tftp"
HTTP_DIR="$SCRIPT_DIR/http"

echo "==> Mounting $IMG"
LOOPDEV=$(losetup --show -f -P "$IMG")
trap 'losetup -d "$LOOPDEV" 2>/dev/null || true; umount /mnt/boot /mnt/root 2>/dev/null || true' EXIT

# RPi4 images: p1 = boot (FAT), p2 = rootfs (ext4)
mkdir -p /mnt/boot /mnt/root
mount "${LOOPDEV}p1" /mnt/boot
mount "${LOOPDEV}p2" /mnt/root

echo "==> Copying boot files to $TFTP_DIR"
mkdir -p "$TFTP_DIR/overlays"
cp /mnt/boot/kernel8.img "$TFTP_DIR/" 2>/dev/null || cp /mnt/boot/kernel.img "$TFTP_DIR/kernel8.img"
cp /mnt/boot/*.dtb "$TFTP_DIR/" 2>/dev/null || true
cp -r /mnt/boot/overlays/* "$TFTP_DIR/overlays/" 2>/dev/null || true
cp /mnt/boot/cmdline.txt "$TFTP_DIR/"
cp /mnt/boot/config.txt "$TFTP_DIR/"

echo "==> Copying rootfs to $HTTP_DIR"
mkdir -p "$HTTP_DIR/rootfs"
# Copy the rootfs (can be large — use rsync for incremental updates)
rsync -a --delete /mnt/root/ "$HTTP_DIR/rootfs/" 2>/dev/null || cp -a /mnt/root/. "$HTTP_DIR/rootfs/"

echo "==> Patching cmdline.txt to point rootfs at HTTP"
SERVER_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
echo "    Detected server IP: $SERVER_IP"
sed -i "s|root=[^ ]*|root=http://$SERVER_IP/rootfs rootfstype=ext4 rootwait|" "$TFTP_DIR/cmdline.txt"
# Also add the server IP for NFS if needed
sed -i "s|\$SERVER_IP|$SERVER_IP|g" "$TFTP_DIR/cmdline.txt" 2>/dev/null || true

umount /mnt/boot /mnt/root
losetup -d "$LOOPDEV"
trap - EXIT

echo "==> Done. Boot files in $TFTP_DIR, rootfs in $HTTP_DIR"
echo "    Start the PXE server: cd $SCRIPT_DIR && docker compose up -d"
