#!/bin/sh
# Generates usb.img with the test SSH public key for automated tests.
# Based on scripts/create-usb.sh.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IMG="${1:-$SCRIPT_DIR/usb.img}"
PUBKEY="$SCRIPT_DIR/test_ssh_key.pub"

if [ ! -f "$PUBKEY" ]; then
    echo "ERROR: $PUBKEY not found. Run ssh-keygen first." >&2
    exit 1
fi

dd if=/dev/zero of="$IMG" count=50 bs=1M

LOOPDEV=$(losetup --show -f -P "$IMG")
trap 'losetup -d "$LOOPDEV" 2>/dev/null || true' EXIT

parted -s "$LOOPDEV" mklabel msdos
parted -s "$LOOPDEV" mkpart primary 1MiB 100%
mkfs.ext4 -L CONFIG "${LOOPDEV}p1"

mount "${LOOPDEV}p1" /mnt
cat "$PUBKEY" > /mnt/authorized_keys
umount /mnt

losetup -d "$LOOPDEV"
trap - EXIT

echo "Created $IMG with test SSH key"
