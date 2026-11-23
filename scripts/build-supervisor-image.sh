#!/bin/bash
# build-supervisor-image.sh - Build and push the patched Hevea Supervisor image
#
# Wraps the stock upstream Supervisor image and patches only
# URL_HASSIO_VERSION (see docker/supervisor/Dockerfile) so devices fetch
# their update metadata from the Hevea update server. The image is published
# per arch under <registry>/<arch>-hassio-supervisor:<version>, which is what
# haos-supervisor (SUPERVISOR_IMAGE) and the version.json "images.supervisor"
# entry point to.
#
# Usage:
#   ./scripts/build-supervisor-image.sh [options]
#
# Options:
#   --version <ver>    Upstream Supervisor version to wrap
#                      (default: .supervisor from buildroot-external/package/hassio/version.json)
#   --arches <list>    Comma-separated arch list (default: amd64,aarch64)
#   --registry <reg>   Target registry prefix (default: ghcr.io/hevea-project)
#   --no-push          Build without pushing (local smoke test)
#   --dry-run          Print what would be done without executing
#   -h, --help         Show this help
#
# Authentication: run `docker login ghcr.io` beforehand, or export
# GITHUB_TOKEN (and optionally GITHUB_USER, default: hevea-project).
#
# Example:
#   ./scripts/build-supervisor-image.sh                  # wrap current version, both arches, push
#   ./scripts/build-supervisor-image.sh --version 2026.10.3 --no-push

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAOS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERSION=""
ARCHES="amd64,aarch64"
REGISTRY="ghcr.io/hevea-project"
PUSH=true
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --arches) ARCHES="$2"; shift 2 ;;
        --registry) REGISTRY="$2"; shift 2 ;;
        --no-push) PUSH=false; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            sed -n '2,26p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [ -z "$VERSION" ]; then
    VERSION="$(jq -r '.supervisor' "${HAOS_ROOT}/buildroot-external/package/hassio/version.json")"
fi

echo "Supervisor version: ${VERSION}"
echo "Registry:           ${REGISTRY}"
echo "Arches:             ${ARCHES}"
echo "Push:               ${PUSH}"

# ---------------------------------------------------------------------------
# Pick a buildx builder that can actually run the RUN steps of non-native
# platforms. The default "docker" driver executes build steps on the host
# kernel, so a linux/arm64 build on an x86_64 host needs a qemu binfmt_misc
# handler. The docker-container driver ships its own qemu, so prefer it when
# the default builder cannot handle a requested platform (this mirrors what
# docker/setup-buildx-action does in .github/workflows/build-supervisor.yml).
# ---------------------------------------------------------------------------
BUILDER="default"
case "$(uname -m)" in
    x86_64)  native_platform="linux/amd64" ;;
    aarch64) native_platform="linux/arm64" ;;
    *)       native_platform="linux/$(uname -m)" ;;
esac
need_container_builder=false
IFS=',' read -ra ARCH_ARRAY <<< "$ARCHES"
for arch in "${ARCH_ARRAY[@]}"; do
    case "$arch" in
        aarch64) platform="linux/arm64" ;;
        *)       platform="linux/${arch}" ;;
    esac
    if [ "$platform" != "$native_platform" ] \
       && ! docker buildx inspect "$BUILDER" --bootstrap 2>/dev/null | grep -q "$platform"; then
        need_container_builder=true
    fi
done
if [ "$need_container_builder" = true ]; then
    if docker buildx inspect hevea-supervisor >/dev/null 2>&1; then
        BUILDER="hevea-supervisor"
    else
        docker buildx create --name hevea-supervisor --driver docker-container
        docker buildx inspect hevea-supervisor --bootstrap
        BUILDER="hevea-supervisor"
    fi
    echo "Using buildx builder '${BUILDER}' (docker-container driver, provides qemu emulation)"
fi

if [ "$DRY_RUN" = false ] && [ "$PUSH" = true ]; then
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        echo "${GITHUB_TOKEN}" | docker login ghcr.io -u "${GITHUB_USER:-hevea-project}" --password-stdin
    fi
fi

IFS=',' read -ra ARCH_ARRAY <<< "$ARCHES"
for arch in "${ARCH_ARRAY[@]}"; do
    case "$arch" in
        aarch64) platform="linux/arm64" ;;
        *)       platform="linux/${arch}" ;;
    esac

    image="${REGISTRY}/${arch}-hassio-supervisor"
    cmd="docker buildx build --builder '${BUILDER}' --platform '${platform}' \
        --build-arg ARCH='${arch}' --build-arg VERSION='${VERSION}' \
        --file '${HAOS_ROOT}/docker/supervisor/Dockerfile' \
        --tag '${image}:${VERSION}' --tag '${image}:latest' \
        $([ "$PUSH" = true ] && echo '--push' || echo '--load') \
        '${HAOS_ROOT}/docker/supervisor'"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] ${cmd}"
    else
        echo "=== Building ${image}:${VERSION} (${platform}) ==="
        eval "$cmd"
    fi
done

if [ "$DRY_RUN" = false ]; then
    echo "Done. Pushed tags per arch: ${VERSION}, latest"
fi
