#!/bin/sh
# grow-data-partition.sh - Grow the hassos-data partition (GPT #8) of a HAOS
# RPi4 disk image so it fills the whole file (the image is truncated to the
# requested size first).
#
# Why: the buildroot image ships a ~400MB data partition, too small for
# Home Assistant + the Supervisor + add-on images once the RPi4 is booted
# diskless from this image over NBD. HAOS's haos-expand resizes the ext4 to
# fill the partition at boot, so growing the partition table is enough.
#
# No root needed: sfdisk/parted work on plain image files.
#
# Usage:
#   ./grow-data-partition.sh <image.img> [total-size]   (default: 8G)

set -eu

IMG="${1:?usage: $0 <image.img> [total-size=8G]}"
SIZE="${2:-8G}"
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }

truncate -s "$SIZE" "$IMG"
TOTAL=$(( $(stat -c %s "$IMG") / 512 ))

DUMP=$(mktemp)
NEW=$(mktemp)
trap 'rm -f "$DUMP" "$NEW"' EXIT

sfdisk -d "$IMG" > "$DUMP"
# In the dump, values are space-padded ("start=     1427456, size=  808960,"),
# so match on the raw line, not on fields.
awk -v total="$TOTAL" '
    /name="hassos-data"/ {
        if (match($0, /start= *[0-9]+/)) {
            s = substr($0, RSTART + 6, RLENGTH - 6)
            gsub(/ /, "", s)
            start = s + 0
        }
        newsize = total - start - 33   # 33 sectors: backup GPT + alignment
        gsub(/size= *[0-9]+/, "size=" newsize)
        print
        next
    }
    { print }
' "$DUMP" > "$NEW"

sfdisk --no-reread --force "$IMG" < "$NEW" 2>/dev/null
echo "==> grown: $(sfdisk -d "$IMG" | grep 'name="hassos-data"')"
echo "    image is now $(stat -c %s "$IMG") bytes apparent, $(du -h "$IMG" | cut -f1) on disk (sparse)"
