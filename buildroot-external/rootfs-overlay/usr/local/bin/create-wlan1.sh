#!/bin/sh
# Attend que wlan0 soit UP avant de créer wlan1

MAX_RETRIES=30
RETRY_DELAY=1

for i in $(seq 1 $MAX_RETRIES); do
    if ip link show wlan0 2>/dev/null | grep -q "state UP"; then
        # wlan0 est UP, vérifie que wlan1 n'existe pas déjà
        if ! iw dev 2>/dev/null | grep -q "wlan1"; then
            iw dev wlan0 interface add wlan1 type __ap
        fi
        exit 0
    fi
    sleep $RETRY_DELAY
done

echo "wlan0 n'est pas passé en état UP après $MAX_RETRIES secondes" >&2
exit 1
