#!/bin/sh
# dnsmasq entrypoint: detect the wired interface IP and pass it to dnsmasq
# as DHCP option 66 (TFTP server — the Pi4 ROM ignores option 67), and
# generate the diskless cmdline.txt (with the NBD server IP) into the
# TFTP root.
#
# Env:
#   PXE_IFACE  wired interface of the PC (default: enp6s0* — USB dongle)
#   PXE_IP     override the detected IP
#   NBD_PORT   NBD port (default 10809)

set -eu

PXE_IFACE="${PXE_IFACE:-enp6s0*}"
NBD_PORT="${NBD_PORT:-10809}"

# Resolve the wildcard to a real interface
IFACE=$(ls /sys/class/net | grep -E "^${PXE_IFACE//\*/.*}$" | head -1)
[ -n "$IFACE" ] || { echo "no interface matching $PXE_IFACE"; ls /sys/class/net; exit 1; }

if [ -n "${PXE_IP:-}" ]; then
    IP="$PXE_IP"
else
    IP=$(ip -4 -o addr show "$IFACE" | awk '{print $4}' | cut -d/ -f1 | head -1)
fi
[ -n "$IP" ] || { echo "no IPv4 on $IFACE"; exit 1; }

echo "entrypoint: iface=$IFACE ip=$IP nbd_port=$NBD_PORT"

# Generate the diskless cmdline.txt into the TFTP root (mounted at /tftpboot)
if [ -f /tftpboot/cmdline.txt.in ]; then
    MAC=$(cat "/sys/class/net/$IFACE/address")
    sed -e "s/@NBD_SERVER@/$IP/g" -e "s/@NBD_PORT@/$NBD_PORT/" -e "s/@PC_MAC@/$MAC/" \
        /tftpboot/cmdline.txt.in > /tftpboot/cmdline.txt
    chmod a+r /tftpboot/cmdline.txt
    echo "entrypoint: wrote /tftpboot/cmdline.txt: $(cat /tftpboot/cmdline.txt)"
fi

exec dnsmasq --no-daemon --log-queries --conf-file=/etc/dnsmasq.conf \
    --interface="$IFACE" --dhcp-option=66,"$IP"
