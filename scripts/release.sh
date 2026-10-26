#!/bin/bash
# release.sh - Build and publish a new Hevea OS release
#
# This script:
#   1. Bumps the version in buildroot-external/meta
#   2. Builds the OS images for specified boards
#   3. Copies the .raucb files to the update server
#   4. Generates and publishes the stable.json version manifest
#
# Usage:
#   ./scripts/release.sh [options]
#
# Options:
#   --version <ver>       Version suffix to set (e.g., dev1, rc1, or empty for release)
#   --boards <list>       Comma-separated list of boards to build (default: rpi4_64,ova)
#   --update-server <url> Update server base URL (default: https://chezbob.glumol.com/hevea)
#   --server-host <host>  SSH host for the update server (default: chezbob.glumol.com)
#   --server-path <path>  Path on the update server (default: /var/www)
#   --channel <name>      Update channel (default: stable)
#   --dry-run             Show what would be done without executing
#   --skip-build          Skip the build step (use existing images)
#   --skip-publish        Skip publishing to the server (local only)
#   -h, --help            Show this help
#
# Examples:
#   # Build and publish a dev release for rpi4_64 and ova
#   ./scripts/release.sh --version dev1 --boards rpi4_64,ova
#
#   # Build a release version (no suffix)
#   ./scripts/release.sh --version "" --boards rpi4_64,rpi5_64,ova
#
#   # Dry run to see what would happen
#   ./scripts/release.sh --version dev2 --dry-run
#
#   # Use existing images, just publish
#   ./scripts/release.sh --version dev1 --skip-build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAOS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Defaults
VERSION_SUFFIX=""
BOARDS="rpi4_64,ova"
UPDATE_SERVER="https://chezbob.glumol.com/hevea"
SERVER_HOST="chezbob.glumol.com"
SERVER_PATH="/var/www/hevea"
CHANNEL="stable"
DRY_RUN=false
SKIP_BUILD=false
SKIP_PUBLISH=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION_SUFFIX="$2"; shift 2 ;;
        --boards) BOARDS="$2"; shift 2 ;;
        --update-server) UPDATE_SERVER="$2"; shift 2 ;;
        --server-host) SERVER_HOST="$2"; shift 2 ;;
        --server-path) SERVER_PATH="$2"; shift 2 ;;
        --channel) CHANNEL="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        --skip-publish) SKIP_PUBLISH=true; shift ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}ℹ${NC} $*"; }
log_ok() { echo -e "${GREEN}✅${NC} $*"; }
log_warn() { echo -e "${YELLOW}⚠️${NC} $*"; }
log_error() { echo -e "${RED}❌${NC} $*" >&2; }
log_step() { echo -e "\n${BLUE}=== $* ===${NC}"; }

run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*"
    else
        eval "$*"
    fi
}

# Save the requested version suffix before sourcing meta (which would overwrite it)
REQUESTED_SUFFIX="$VERSION_SUFFIX"

# Read current version from meta (for major.minor)
META_FILE="${HAOS_ROOT}/buildroot-external/meta"
# shellcheck source=/dev/null
source "$META_FILE"

VERSION_MAJOR="${VERSION_MAJOR:-18}"
VERSION_MINOR="${VERSION_MINOR:-1}"

# Compute the full version string from the --version argument
if [ -n "$REQUESTED_SUFFIX" ]; then
    FULL_VERSION="${VERSION_MAJOR}.${VERSION_MINOR}.${REQUESTED_SUFFIX}"
else
    FULL_VERSION="${VERSION_MAJOR}.${VERSION_MINOR}"
fi

log_step "Hevea OS Release"
log_info "Version: ${FULL_VERSION}"
log_info "Boards: ${BOARDS}"
log_info "Channel: ${CHANNEL}"
log_info "Update server: ${UPDATE_SERVER}"
log_info "Server host: ${SERVER_HOST}:${SERVER_PATH}"
if [ "$DRY_RUN" = true ]; then
    log_warn "DRY RUN MODE - no changes will be made"
fi

# =============================================================================
# Step 1: Update version in meta
# =============================================================================
log_step "Step 1: Update version in meta"

if [ "$DRY_RUN" = false ]; then
    # Update VERSION_SUFFIX in meta
    if [ -n "$REQUESTED_SUFFIX" ]; then
        sed -i "s/^VERSION_SUFFIX=.*/VERSION_SUFFIX=\"${REQUESTED_SUFFIX}\"/" "$META_FILE"
    else
        sed -i 's/^VERSION_SUFFIX=.*/VERSION_SUFFIX=""/' "$META_FILE"
    fi
    log_ok "Updated ${META_FILE}"
else
    log_info "Would update VERSION_SUFFIX to: \"${REQUESTED_SUFFIX}\""
fi

# =============================================================================
# Step 2: Build images
# =============================================================================
if [ "$SKIP_BUILD" = false ]; then
    log_step "Step 2: Build images"

    IFS=',' read -ra BOARD_ARRAY <<< "$BOARDS"
    for board in "${BOARD_ARRAY[@]}"; do
        log_info "Building ${board}..."
        run_cmd "cd '${HAOS_ROOT}' && make '${board}' 2>&1 | tee '${HAOS_ROOT}/${board}.log'"
    done
    log_ok "Build complete"
else
    log_step "Step 2: Build images (SKIPPED)"
    log_warn "Using existing images"
fi

# =============================================================================
# Step 3: Collect .raucb files
# =============================================================================
log_step "Step 3: Collect .raucb files"

declare -A RAUCB_FILES  # board -> path to .raucb

IFS=',' read -ra BOARD_ARRAY <<< "$BOARDS"
for board in "${BOARD_ARRAY[@]}"; do
    # Get board_id from the board meta
    BOARD_META=$(find "${HAOS_ROOT}/buildroot-external/board" -path "*/${board}/meta" 2>/dev/null | head -1)
    if [ -z "$BOARD_META" ]; then
        # Try alternative path patterns
        BOARD_META=$(find "${HAOS_ROOT}/buildroot-external/board" -name "meta" -exec grep -l "BOARD_ID=" {} \; 2>/dev/null | while read -r f; do
            bid=$(grep "^BOARD_ID=" "$f" | cut -d= -f2)
            if [ "$bid" = "${board//_/-}" ]; then echo "$f"; fi
        done | head -1)
    fi

    if [ -n "$BOARD_META" ]; then
        # shellcheck source=/dev/null
        source "$BOARD_META"
        BOARD_ID="${BOARD_ID:-${board//_/-}}"
    else
        BOARD_ID="${board//_/-}"
    fi

    # Find the .raucb file matching the target version
    RAUCB_PATH="${HAOS_ROOT}/output_${board}/images/haos_${BOARD_ID}-${FULL_VERSION}.raucb"

    if [ ! -f "$RAUCB_PATH" ]; then
        # If exact version not found, check if we're in skip-build mode and
        # fall back to any existing .raucb for this board (with a warning)
        if [ "$SKIP_BUILD" = true ]; then
            RAUCB_PATH=$(find "${HAOS_ROOT}/output_${board}/images" -name "haos_${BOARD_ID}-*.raucb" 2>/dev/null | head -1)
            if [ -n "$RAUCB_PATH" ] && [ -f "$RAUCB_PATH" ]; then
                log_warn "Using existing image (version mismatch): $(basename "$RAUCB_PATH")"
                log_warn "Expected version ${FULL_VERSION}, found $(basename "$RAUCB_PATH" | sed "s/haos_${BOARD_ID}-//;s/\.raucb//")"
            fi
        fi
    fi

    if [ -n "$RAUCB_PATH" ] && [ -f "$RAUCB_PATH" ]; then
        RAUCB_FILES["$BOARD_ID"]="$RAUCB_PATH"
        log_ok "Found: ${BOARD_ID} -> $(basename "$RAUCB_PATH") ($(du -h "$RAUCB_PATH" | cut -f1))"
    else
        log_error "Not found: haos_${BOARD_ID}-${FULL_VERSION}.raucb in output_${board}/images/"
        log_error "Run without --skip-build to build the images first."
    fi
done

if [ ${#RAUCB_FILES[@]} -eq 0 ]; then
    log_error "No .raucb files found!"
    exit 1
fi

# =============================================================================
# Step 4: Generate stable.json
# =============================================================================
log_step "Step 4: Generate version manifest"

# Use the first board's output directory for version.json
FIRST_BOARD=$(echo "$BOARDS" | cut -d',' -f1)
VERSION_JSON_DIR="output_${FIRST_BOARD}"

STABLE_JSON="${HAOS_ROOT}/${CHANNEL}.json"

run_cmd "'${HAOS_ROOT}/scripts/generate-version-json.sh' '${VERSION_JSON_DIR}' \
    --channel '${CHANNEL}' \
    --update-server '${UPDATE_SERVER}' \
    --output '${STABLE_JSON}'"

if [ "$DRY_RUN" = false ] && [ -f "$STABLE_JSON" ]; then
    log_ok "Generated: ${STABLE_JSON}"
    log_info "OS version in manifest: $(jq -r '.hassos | to_entries[0].value' "$STABLE_JSON")"
    log_info "Boards in manifest: $(jq -r '.hassos | keys | join(", ")' "$STABLE_JSON")"
fi

# =============================================================================
# Step 5: Publish to update server
# =============================================================================
if [ "$SKIP_PUBLISH" = false ]; then
    log_step "Step 5: Publish to update server"

    # Structure on server (matching the OTA URL pattern):
    #   ${SERVER_PATH}/${CHANNEL}.json                    ← version manifest
    #   ${SERVER_PATH}/${FULL_VERSION}/haos_<board>-<ver>.raucb  ← OTA bundles
    #   ${SERVER_PATH}/apparmor_${CHANNEL}.txt            ← AppArmor profile
    #   ${SERVER_PATH}/online.txt                         ← connectivity check
    REMOTE_VERSION_DIR="${SERVER_PATH}/${FULL_VERSION}"

    log_info "Creating directories on ${SERVER_HOST}..."
    run_cmd "ssh '${SERVER_HOST}' 'sudo mkdir -p ${REMOTE_VERSION_DIR} && sudo chown -R \$(whoami) ${SERVER_PATH}'"

    # Copy .raucb files (renamed to match the target version)
    log_info "Uploading .raucb files to ${FULL_VERSION}/..."
    for board_id in "${!RAUCB_FILES[@]}"; do
        raucb="${RAUCB_FILES[$board_id]}"
        # Target filename: haos_<board_id>-<FULL_VERSION>.raucb
        target_name="haos_${board_id}-${FULL_VERSION}.raucb"
        local_name=$(basename "$raucb")

        if [ "$local_name" != "$target_name" ]; then
            log_info "  Uploading: ${local_name} -> ${target_name}"
        else
            log_info "  Uploading: ${target_name}"
        fi

        if [ "$DRY_RUN" = false ]; then
            # Copy to temp with correct name, then scp
            tmp_file=$(mktemp)
            cp "$raucb" "$tmp_file"
            scp "$tmp_file" "${SERVER_HOST}:${REMOTE_VERSION_DIR}/${target_name}"
            rm -f "$tmp_file"
        else
            echo -e "${YELLOW}[DRY-RUN]${NC} scp '${raucb}' '${SERVER_HOST}:${REMOTE_VERSION_DIR}/${target_name}'"
        fi
    done

    # Copy stable.json to server root
    log_info "Uploading ${CHANNEL}.json..."
    run_cmd "scp '${STABLE_JSON}' '${SERVER_HOST}:${SERVER_PATH}/${CHANNEL}.json'"

    # Copy AppArmor profile if it exists
    APPARMOR_FILE="${HAOS_ROOT}/buildroot-external/ota/apparmor_${CHANNEL}.txt"
    if [ -f "$APPARMOR_FILE" ]; then
        log_info "Uploading apparmor_${CHANNEL}.txt..."
        run_cmd "scp '${APPARMOR_FILE}' '${SERVER_HOST}:${SERVER_PATH}/apparmor_${CHANNEL}.txt'"
    fi

    # Create online.txt for connectivity check
    log_info "Creating online.txt..."
    run_cmd "ssh '${SERVER_HOST}' 'echo \"online\" > ${SERVER_PATH}/online.txt'"

    log_ok "Published to ${SERVER_HOST}:${SERVER_PATH}"
else
    log_step "Step 5: Publish to update server (SKIPPED)"
    log_warn "Files are ready locally:"
    for board_id in "${!RAUCB_FILES[@]}"; do
        log_info "  ${RAUCB_FILES[$board_id]}"
    done
    log_info "  ${STABLE_JSON}"
fi

# =============================================================================
# Done
# =============================================================================
log_step "Release complete!"

log_ok "Version ${FULL_VERSION} is ready"
echo ""
echo "Update server structure:"
echo "  ${SERVER_PATH}/${CHANNEL}.json                    ← version manifest"
echo "  ${SERVER_PATH}/${FULL_VERSION}/                   ← OTA bundles"
for board_id in "${!RAUCB_FILES[@]}"; do
    echo "    haos_${board_id}-${FULL_VERSION}.raucb"
done
echo "  ${SERVER_PATH}/apparmor_${CHANNEL}.txt            ← AppArmor profile"
echo "  ${SERVER_PATH}/online.txt                         ← connectivity check"
echo ""
echo "Devices will check for updates at:"
echo "  ${UPDATE_SERVER}/${CHANNEL}.json"
echo ""
echo "OTA URL pattern:"
echo "  ${UPDATE_SERVER}/{version}/{os_name}_{board}-{version}.raucb"
