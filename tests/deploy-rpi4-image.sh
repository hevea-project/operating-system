#!/bin/sh
# deploy-rpi4-image.sh - Deploy a freshly built Hevea OS rpi4 image to the
# physical RPi4 used by the labgrid tests, WITHOUT an SD card:
#
#   new .img -> extract boot files + NBD disk copy (this PC)
#            -> push them to the PXE server (local, or a remote host via SSH:
#               set PXE_SSH_HOST, e.g. a wired "groszordi" on the RPi4's LAN so
#               this PC can stay on WiFi — only DHCP/TFTP broadcasts need the
#               same L2 segment, unicast app/VPN traffic routes fine)
#            -> power-cycle the RPi4 through its Home Assistant plug
#            -> wait for SSH -> print the booted version
#
# Usage:
#   ./deploy-rpi4-image.sh [options] [path/to/hevea_rpi4-64-<ver>.img[.xz]]
#
# Options:
#   --flash-sd   after the diskless boot, serve the .img over the pxe-server
#                HTTP container (:8880) and dd it onto /dev/mmcblk0 FROM the
#                RPi4 itself (SD card inserted), then power off. The SD then
#                holds the image and the RPi4 can boot from SD afterwards.
#   --no-boot    stop after (re)starting the pxe-server, do not power-cycle
#   -h, --help   show this help
#
# Env (same variables as the labgrid RPi PXE strategy, hevea-rpi-pxe-strategy.yaml):
#   LG_RPI_IP       fixed DHCP IP of the RPi4 (MAC dc:a6:32:14:63:44), default 192.168.1.150
#   LG_HA_URL       Home Assistant URL (e.g. http://raspberrypi4)
#   LG_HA_TOKEN     HA long-lived access token (default: hevea_test/token)
#   LG_RPI_SWITCH   HA switch entity powering the RPi4 (e.g. switch.eve_energy)
#   PXE_SSH_HOST    if set, the pxe-server (DHCP+TFTP+NBD+HTTP) runs on this SSH
#                   host instead of this PC (default: empty = local)
#   PXE_REMOTE_DIR  pxe-server dir on PXE_SSH_HOST
#                   (default /home/bob/dev/hevea/homeassistant/operating-system/tests/hevea_test/pxe-server)
#   PXE_REMOTE_IFACE wired iface on PXE_SSH_HOST (default: first en* iface)
#   PXE_SERVER_IP   LAN IP of the pxe-server (default: detected on PXE_REMOTE_IFACE)
#   PXE_IFACE       (local mode) wired iface of this PC (default: enp6s0*)
#
# Prereq: a finished rpi4_64 build (output_rpi4_64/), rsync, and on the pxe-server
# host: docker + compose, ports 67/udp, 69/udp, 10809/tcp open on the wired iface.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OS_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PXE_DIR="$SCRIPT_DIR/hevea_test/pxe-server"
OUTPUT_DIR="$OS_ROOT/output_rpi4_64"
SSH_KEY="$SCRIPT_DIR/hevea_test/test_ssh_key"

FLASH_SD=false
DO_BOOT=true
IMG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --flash-sd) FLASH_SD=true; shift ;;
        --no-boot)  DO_BOOT=false; shift ;;
        -h|--help)  sed -n '2,31p' "$0"; exit 0 ;;
        *)          IMG="$1"; shift ;;
    esac
done

LG_RPI_IP="${LG_RPI_IP:-192.168.1.150}"
LG_HA_URL="${LG_HA_URL:?set LG_HA_URL (Home Assistant URL)}"
LG_HA_TOKEN="${LG_HA_TOKEN:-$(cat "$SCRIPT_DIR/hevea_test/token" 2>/dev/null || true)}"
LG_RPI_SWITCH="${LG_RPI_SWITCH:?set LG_RPI_SWITCH (HA switch entity powering the RPi4)}"
PXE_SSH_HOST="${PXE_SSH_HOST:-}"
PXE_REMOTE_DIR="${PXE_REMOTE_DIR:-/home/bob/dev/hevea/homeassistant/operating-system/tests/hevea_test/pxe-server}"
PXE_REMOTE_IFACE="${PXE_REMOTE_IFACE:-}"
PXE_SERVER_IP="${PXE_SERVER_IP:-}"
PXE_IFACE="${PXE_IFACE:-enp6s0*}"

[ -n "$LG_HA_TOKEN" ] || { echo "LG_HA_TOKEN empty and hevea_test/token missing" >&2; exit 1; }

if [ -z "$IMG" ]; then
    IMG=$(ls -t "$OUTPUT_DIR"/images/hevea_rpi4-64-*.img "$OUTPUT_DIR"/images/hevea_rpi4-64-*.img.xz 2>/dev/null | head -1 || true)
fi
[ -n "$IMG" ] && [ -f "$IMG" ] || { echo "image not found: ${IMG:-none in $OUTPUT_DIR/images/hevea_rpi4-64-*}" >&2; exit 1; }
case "$IMG" in
    *.xz) [ -f "${IMG%.xz}" ] || unxz -k "$IMG"; IMG="${IMG%.xz}" ;;
esac
IMG=$(CDPATH= cd -- "$(dirname "$IMG")" && pwd)/$(basename "$IMG")
echo "==> Image: $IMG ($(du -h "$IMG" | cut -f1) on disk, $(stat -c %s "$IMG") apparent)"

ha_switch() {
    curl -sf -X POST \
        -H "Authorization: Bearer $LG_HA_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"entity_id\":\"$LG_RPI_SWITCH\"}" \
        "$LG_HA_URL/api/services/switch/$1"
}

# ssh to the pxe-server host: BatchMode + no local forwards (a stale forward
# in ~/.ssh/config otherwise spams "Address already in use" on every call)
rssh() {
    ssh -o BatchMode=yes -o ClearAllForwardings=yes "$PXE_SSH_HOST" "$@"
}

# --- resolve where the pxe-server runs and its LAN IP (SRV_IP) -----------
if [ -n "$PXE_SSH_HOST" ]; then
    if [ -z "$PXE_REMOTE_IFACE" ]; then
        PXE_REMOTE_IFACE=$(rssh "ls /sys/class/net | grep -E '^en' | head -1")
    fi
    [ -n "$PXE_REMOTE_IFACE" ] || { echo "no wired iface found on $PXE_SSH_HOST" >&2; exit 1; }
    if [ -z "$PXE_SERVER_IP" ]; then
        PXE_SERVER_IP=$(rssh "ip -4 -o addr show '$PXE_REMOTE_IFACE' | awk '{print \$4}' | cut -d/ -f1 | head -1")
    fi
    [ -n "$PXE_SERVER_IP" ] || { echo "no IPv4 on $PXE_SSH_HOST:$PXE_REMOTE_IFACE" >&2; exit 1; }
    SRV_IP="$PXE_SERVER_IP"
    echo "==> PXE server: remote $PXE_SSH_HOST iface=$PXE_REMOTE_IFACE ip=$SRV_IP dir=$PXE_REMOTE_DIR"
    # stop a possibly running LOCAL pxe-server: two DHCP servers on the same
    # LAN would race for the RPi4's PXE requests
    (cd "$PXE_DIR" && docker compose down) 2>/dev/null || true
else
    IFACE=$(ls /sys/class/net | grep -E "^${PXE_IFACE//\*/.*}$" | head -1)
    [ -n "$IFACE" ] || { echo "no interface matching $PXE_IFACE" >&2; ls /sys/class/net; exit 1; }
    SRV_IP=$(ip -4 -o addr show "$IFACE" | awk '{print $4}' | cut -d/ -f1 | head -1)
    [ -n "$SRV_IP" ] || { echo "no IPv4 on $IFACE" >&2; exit 1; }
    echo "==> PXE server: local iface=$IFACE ip=$SRV_IP"
fi

# --- power off first: the NBD image file is replaced below, a running RPi4
# --- must not have it open
if [ "$DO_BOOT" = true ]; then
    echo "==> power off ($LG_RPI_SWITCH)"
    ha_switch turn_off
    sleep 5
fi

# --- 1. generate boot files + NBD disk copy locally -----------------------
echo "==> extract-boot-files.sh"
(cd "$PXE_DIR" && ./extract-boot-files.sh "$IMG")

# --- 2. diskless initramfs (embeds SRV_IP as NBD fallback + watchdog) -----
echo "==> make-initramfs.sh (nbd server $SRV_IP)"
(cd "$PXE_DIR" && ./make-initramfs.sh "$OUTPUT_DIR" "$SRV_IP")

if [ "$FLASH_SD" = true ]; then
    echo "==> copying image into http/ for the SD flash (served on :8880)"
    mkdir -p "$PXE_DIR/http"
    cp --sparse=always "$IMG" "$PXE_DIR/http/$(basename "$IMG")"
fi

# --- 3. (re)start the pxe-server ------------------------------------------
if [ -n "$PXE_SSH_HOST" ]; then
    echo "==> rsync pxe-server to $PXE_SSH_HOST:$PXE_REMOTE_DIR"
    rssh "mkdir -p '$PXE_REMOTE_DIR/nbd' '$PXE_REMOTE_DIR/http'"
    rsync -a --delete \
        --exclude '__pycache__/' --exclude 'token' --exclude 'nbd/' --exclude 'http/' \
        --exclude '*.img' --exclude '*.img.xz' \
        "$PXE_DIR/" "$PXE_SSH_HOST:$PXE_REMOTE_DIR/"
    # the NBD image separately: sparse + compressed, only real blocks cross
    # the LAN (the image is mostly empty space)
    rsync -a --sparse -z "$PXE_DIR/nbd/hevea_rpi4.img" "$PXE_SSH_HOST:$PXE_REMOTE_DIR/nbd/hevea_rpi4.img"
    if [ "$FLASH_SD" = true ]; then
        rsync -a --sparse -z "$PXE_DIR/http/$(basename "$IMG")" "$PXE_SSH_HOST:$PXE_REMOTE_DIR/http/$(basename "$IMG")"
    fi
    echo "==> docker compose up -d --force-recreate on $PXE_SSH_HOST"
    rssh "cd '$PXE_REMOTE_DIR' && PXE_IFACE='$PXE_REMOTE_IFACE' docker compose up -d --force-recreate"
else
    echo "==> docker compose up -d --force-recreate (local)"
    (cd "$PXE_DIR" && docker compose up -d --force-recreate)
fi

if [ "$DO_BOOT" = false ]; then
    echo "==> --no-boot: pxe-server restarted on ${PXE_SSH_HOST:-localhost} ($SRV_IP), RPi4 not power-cycled. Done."
    exit 0
fi

# --- 4. power on -> PXE boot -> wait for SSH -------------------------------
echo "==> power on -> PXE boot"
ha_switch turn_on

echo "==> waiting for SSH root@$LG_RPI_IP:22222 (timeout 300s)"
SSH="ssh -i $SSH_KEY -p 22222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes root@$LG_RPI_IP"
BOOTED=false
i=0
while [ $i -lt 60 ]; do
    if $SSH true 2>/dev/null; then BOOTED=true; break; fi
    i=$((i + 1)); sleep 5
done
[ "$BOOTED" = true ] || {
    echo "SSH never came up on $LG_RPI_IP:22222." >&2
    if [ -n "$PXE_SSH_HOST" ]; then
        echo "Check on $PXE_SSH_HOST: docker compose ps/log in $PXE_REMOTE_DIR" >&2
        echo "(tftp/cmdline.txt must contain nbd=$SRV_IP:10809), and that the RPi4 did a" >&2
        echo "DHCP/PXE boot (tcpdump -i $PXE_REMOTE_IFACE port 67 or 68 or 69 on $PXE_SSH_HOST)." >&2
    else
        echo "Check: docker compose ps/log in $PXE_DIR (cmdline.txt must contain nbd=$SRV_IP:10809)," >&2
        echo "and that the RPi4 did a DHCP/PXE boot (tcpdump port 67/68/69 on $IFACE)." >&2
    fi
    exit 1
}

echo "==> booted. /etc/os-release:"
$SSH 'grep -E "^(NAME|ID|VERSION|VERSION_ID)=" /etc/os-release || cat /usr/lib/os-release'
echo "==> rauc status:"
$SSH 'rauc status --output-format=shell 2>/dev/null | grep -E "^(RAUC_SYSTEM_BOOTED|RAUC_BOOT_PRIMARY)" || true'

if [ "$FLASH_SD" = true ]; then
    echo "==> flashing SD card (/dev/mmcblk0) from the RPi4 itself (http://$SRV_IP:8880/)"
    $SSH "wget -q http://$SRV_IP:8880/$(basename "$IMG") -O /tmp/deploy.img \
          && dd if=/tmp/deploy.img of=/dev/mmcblk0 bs=4M conv=fsync status=progress \
          && sync && rm -f /tmp/deploy.img && echo SD_FLASH_OK"
    echo "==> power off; the SD card now holds $(basename "$IMG") (SD boot works from now on)"
    ha_switch turn_off
fi

echo "==> Done. Deployed $(basename "$IMG") on the RPi4 at $LG_RPI_IP (pxe-server: ${PXE_SSH_HOST:-local} $SRV_IP)"
