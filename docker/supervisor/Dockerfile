# Patched Home Assistant Supervisor image for Hevea OS.
#
# Only URL_HASSIO_VERSION is changed: the Supervisor fetches its update
# metadata (OS/Core/Supervisor versions, OTA URL) from the Hevea update
# server instead of version.home-assistant.io, so devices running Hevea OS
# see and install Hevea OS updates. Everything else is the stock upstream
# image, byte for byte.
#
# Build and push one image per arch, tagged with the upstream Supervisor
# version (this is the tag haos-supervisor and version.json use):
#
#   docker buildx build --platform linux/amd64 \
#       --build-arg ARCH=amd64 --build-arg VERSION=2026.10.3 \
#       -t ghcr.io/hevea-project/amd64-hassio-supervisor:2026.10.3 \
#       --push docker/supervisor
#
# or simply: scripts/build-supervisor-image.sh

ARG ARCH=amd64
ARG VERSION
FROM ghcr.io/home-assistant/${ARCH}-hassio-supervisor:${VERSION}

RUN const_py="$(find /usr/src -path '*/.git' -prune -o -path '*/supervisor/const.py' -print | head -1)" \
    && test -n "${const_py}" \
    && sed -i 's|https://version\.home-assistant\.io/{channel}\.json|https://chezbob.glumol.com/hevea/{channel}.json|' "${const_py}" \
    && grep -q 'URL_HASSIO_VERSION = "https://chezbob.glumol.com/hevea/{channel}.json"' "${const_py}"
