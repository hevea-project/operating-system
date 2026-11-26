#!/bin/sh
# onboard-rpi4.sh - Onboard an already-booted RPi4 through its gateway portal:
# point the gateway at the host app, optionally provision the lab WiFi
# (HEVEA_WIFI_SSID/HEVEA_WIFI_PASSWORD), commission the site, then verify the
# VPN tunnel, the HA command_line login and a clean Settings -> Repairs.
#
# Usage:
#   ./onboard-rpi4.sh [--wait-boot] [--no-wifi] [-- --ip <ip>]
#
# Options:
#   --wait-boot   wait up to 300s for SSH (use right after a deploy/power-cycle)
#   --no-wifi     skip WiFi provisioning even if HEVEA_WIFI_SSID is set
#   extra args are passed to hevea_test/onboard_rpi4.py (e.g. --ip 192.168.1.150)
#
# Env (same as the labgrid tests):
#   LG_RPI_IP         target IP (default 192.168.1.150)
#   HEVEA_APP_URL     app URL from this host (default http://localhost:7030)
#   HEVEA_ADMIN_EMAIL / HEVEA_ADMIN_PASSWORD  app + HA credentials
#   HEVEA_WIFI_SSID / HEVEA_WIFI_PASSWORD      lab WiFi provisioned via the portal
#   HEVEA_VM_APP_ADDR app URL as seen from the target (default: auto-detected)
#
# Example (right after ./deploy-rpi4-image.sh):
#   HEVEA_WIFI_SSID='...' HEVEA_WIFI_PASSWORD='...' ./onboard-rpi4.sh --wait-boot

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ -x "$SCRIPT_DIR/venv/bin/python3" ]; then
    PY="$SCRIPT_DIR/venv/bin/python3"
else
    PY=python3
fi

cd "$SCRIPT_DIR"
exec "$PY" hevea_test/onboard_rpi4.py "$@"
