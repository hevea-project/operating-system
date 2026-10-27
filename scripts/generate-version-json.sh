#!/bin/bash
# generate-version-json.sh - Generate stable.json for Hevea OS update server
#
# This script merges the version.json generated during the HAOS build (which
# contains the official Home Assistant component versions) with Hevea-specific
# overrides (OS version, OTA URL pointing to your update server).
#
# Usage:
#   ./scripts/generate-version-json.sh <build_output_dir> [options]
#
# Arguments:
#   <build_output_dir>   Path to the build output directory (e.g., output_rpi4_64)
#
# Options:
#   --channel <name>     Update channel (default: stable)
#   --update-server <url>  Your update server URL (default: https://chezbob.glumol.com/hevea)
#   --output <file>      Output file (default: stable.json)
#   --boards <list>      Comma-separated list of boards to include (default: all)
#
# Example:
#   ./scripts/generate-version-json.sh output_rpi4_64 \
#       --channel stable \
#       --update-server https://chezbob.glumol.com/hevea \
#       --output stable.json
#
# The script reads:
#   - <build_output_dir>/build/hassio-1.0.0/version.json (official HA versions)
#   - buildroot-external/meta (Hevea OS version)
#   - buildroot-external/board/*/*/meta (board IDs and machine names)
#
# And produces a stable.json that can be served by your update server.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAOS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Defaults
CHANNEL="stable"
UPDATE_SERVER="https://chezbob.glumol.com/hevea"
OUTPUT_FILE="stable.json"
BOARDS_FILTER=""

# Parse arguments
BUILD_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel) CHANNEL="$2"; shift 2 ;;
        --update-server) UPDATE_SERVER="$2"; shift 2 ;;
        --output) OUTPUT_FILE="$2"; shift 2 ;;
        --boards) BOARDS_FILTER="$2"; shift 2 ;;
        -h|--help)
            head -30 "$0" | tail -25
            exit 0
            ;;
        *)
            if [ -z "$BUILD_DIR" ]; then
                BUILD_DIR="$1"
            else
                echo "Unknown option: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -z "$BUILD_DIR" ]; then
    echo "Error: build output directory is required" >&2
    echo "Usage: $0 <build_output_dir> [options]" >&2
    exit 1
fi

BUILD_DIR="${HAOS_ROOT}/${BUILD_DIR}"
if [ ! -d "$BUILD_DIR" ]; then
    echo "Error: build directory not found: $BUILD_DIR" >&2
    exit 1
fi

# Find the version.json generated during the build
VERSION_JSON=$(find "${BUILD_DIR}/build" -name "version.json" -path "*/hassio-*" 2>/dev/null | head -1)
if [ -z "$VERSION_JSON" ]; then
    echo "Error: version.json not found in ${BUILD_DIR}/build/hassio-*/" >&2
    echo "Have you run a build yet?" >&2
    exit 1
fi
echo "📄 Using version.json: ${VERSION_JSON}"

# Read Hevea OS version from meta
META_FILE="${HAOS_ROOT}/buildroot-external/meta"
if [ ! -f "$META_FILE" ]; then
    echo "Error: meta file not found: $META_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$META_FILE"

# Compute OS version (same logic as scripts/name.sh haos_version)
if [ -z "${VERSION_SUFFIX}" ]; then
    OS_VERSION="${VERSION_MAJOR}.${VERSION_MINOR}"
else
    OS_VERSION="${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_SUFFIX}"
fi
OS_NAME="${HAOS_ID:-haos}"

echo "📦 Hevea OS version: ${OS_VERSION} (${OS_NAME})"
echo "📡 Update server: ${UPDATE_SERVER}"
echo "📡 Channel: ${CHANNEL}"

# Collect board information from board/*/*/meta files
declare -A BOARD_IDS      # board_id -> true
declare -A BOARD_MACHINES # board_id -> supervisor_machine

for meta in "${HAOS_ROOT}"/buildroot-external/board/*/*/meta; do
    [ -f "$meta" ] || continue

    # shellcheck source=/dev/null
    source "$meta"

    if [ -n "${BOARD_ID:-}" ]; then
        # Apply board filter if specified
        if [ -n "$BOARDS_FILTER" ]; then
            if ! echo ",$BOARDS_FILTER," | grep -q ",${BOARD_ID},"; then
                continue
            fi
        fi

        BOARD_IDS["$BOARD_ID"]=1
        BOARD_MACHINES["$BOARD_ID"]="${SUPERVISOR_MACHINE:-$BOARD_ID}"
    fi
done

echo "📋 Boards found: ${!BOARD_IDS[*]}"

# Build the hassos object (board_id -> OS version)
HASSOS_JSON="{"
first=true
for board_id in "${!BOARD_IDS[@]}"; do
    if [ "$first" = true ]; then
        first=false
    else
        HASSOS_JSON+=","
    fi
    HASSOS_JSON+="\"${board_id}\": \"${OS_VERSION}\""
done
HASSOS_JSON+="}"

# Build the homeassistant object (machine -> core version from version.json)
# We take the "default" core version and apply it to all our boards
CORE_VERSION=$(jq -r '.homeassistant.default' "$VERSION_JSON")
HA_JSON="{\"default\": \"${CORE_VERSION}\""
for board_id in "${!BOARD_IDS[@]}"; do
    machine="${BOARD_MACHINES[$board_id]}"
    HA_JSON+=",\"${machine}\": \"${CORE_VERSION}\""
done
HA_JSON+="}"

# Build hassos-upgrade object (map old major versions to current)
# For a custom spin, we map all old versions to our current version
HASSOS_UPGRADE="{"
first=true
for major in 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
    if [ "$first" = true ]; then
        first=false
    else
        HASSOS_UPGRADE+=","
    fi
    HASSOS_UPGRADE+="\"${major}\": \"${OS_VERSION}\""
done
HASSOS_UPGRADE+="}"

# OTA URL template
# {version} = OS version, {os_name} = haos, {board} = board_id
OTA_URL="${UPDATE_SERVER}/{version}/{os_name}_{board}-{version}.raucb"

# Merge with version.json: take everything from version.json, override hassos,
# homeassistant, hassos-upgrade, ota, and channel
jq -n \
    --slurpfile v "$VERSION_JSON" \
    --arg channel "$CHANNEL" \
    --argjson hassos "$HASSOS_JSON" \
    --argjson homeassistant "$HA_JSON" \
    --argjson hassos_upgrade "$HASSOS_UPGRADE" \
    --arg ota "$OTA_URL" \
    '
    # Start with the official version.json
    $v[0]
    # Override channel
    + {channel: $channel}
    # Override hassos versions (our OS version for all boards)
    + {hassos: $hassos}
    # Override homeassistant versions (same core version for all our boards)
    + {homeassistant: $homeassistant}
    # Override hassos-upgrade (all old versions upgrade to our version)
    + {"hassos-upgrade": $hassos_upgrade}
    # Override OTA URL (point to our update server)
    + {ota: $ota}
    ' > "$OUTPUT_FILE"

echo "✅ Generated: ${OUTPUT_FILE}"
echo ""
echo "Summary:"
echo "  Channel:     ${CHANNEL}"
echo "  OS version:  ${OS_VERSION}"
echo "  OTA URL:     ${OTA_URL}"
echo "  Boards:      ${#BOARD_IDS[@]}"
echo "  Supervisor:  $(jq -r '.supervisor' "$OUTPUT_FILE")"
echo "  Core:        $(jq -r '.homeassistant.default' "$OUTPUT_FILE")"
echo ""
echo "Next steps:"
echo "  1. Copy ${OUTPUT_FILE} to your update server (e.g., /var/www/version/)"
echo "  2. Copy the .raucb files to ${UPDATE_SERVER}/{version}/"
echo "  3. Point your devices to ${UPDATE_SERVER} (via DNS override or build config)"
