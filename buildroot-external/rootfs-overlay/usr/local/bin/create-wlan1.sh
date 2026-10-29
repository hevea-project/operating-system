#!/bin/sh
# Attend que wlan0 existe avant de créer wlan1. Pas besoin qu'il soit UP :
# iw crée une interface virtuelle (__ap) même sur une interface down, et
# sur un device frais wlan0 n'est jamais UP avant le commissioning (il
# n'a pas encore de wifi configuré) — attendre UP empêcherait wlan1
# d'être créé, donc l'AP, donc le commissioning.

MAX_RETRIES=30
RETRY_DELAY=1

for i in $(seq 1 $MAX_RETRIES); do
    if ip link show wlan0 >/dev/null 2>&1; then
        # wlan0 existe, vérifie que wlan1 n'existe pas déjà
        if ! iw dev 2>/dev/null | grep -q "wlan1"; then
            iw dev wlan0 interface add wlan1 type __ap
        fi
        exit 0
    fi
    sleep $RETRY_DELAY
done

echo "wlan0 n'est pas apparu après $MAX_RETRIES secondes" >&2
exit 1
