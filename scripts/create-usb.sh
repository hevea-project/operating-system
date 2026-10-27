#!/bin/sh

IMG=usb.img
dd if=/dev/zero of=$IMG count=50 bs=1M

# -f : premier loop libre, --show : l'affiche, -P : crée les /dev/loopXpY
LOOPDEV=$(losetup --show -f -P $IMG)
echo "LOOPDEV = $LOOPDEV"

echo parted -s $LOOPDEV mklabel msdos
parted -s $LOOPDEV mklabel msdos
echo parted -s $LOOPDEV mkpart primary 1MiB 100%
parted -s $LOOPDEV mkpart primary 1MiB 100%
echo mkfs.ext4 -L CONFIG ${LOOPDEV}p1
mkfs.ext4 -L CONFIG ${LOOPDEV}p1

echo mount ${LOOPDEV}p1 /mnt
mount ${LOOPDEV}p1 /mnt
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAur4Q25GSltVoShSaRL2l/geNH59KFopztg/qfRcBUf bob@lezordi" > /mnt/authorized_keys
echo umount /mnt
umount /mnt

echo losetup -d $LOOPDEV
losetup -d $LOOPDEV
