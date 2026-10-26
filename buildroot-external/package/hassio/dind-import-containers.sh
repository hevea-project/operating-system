#!/bin/sh
set -e

# Make sure we can talk to the Docker daemon
echo "Waiting for Docker daemon..."
while ! docker version 2> /dev/null > /dev/null; do
	sleep 1
done

# Install Supervisor, plug-ins and landing page
echo "Loading container images..."

# Make sure to order images by size (largest first)
# It seems docker load requires space during operation
# shellcheck disable=SC2045
for image in $(ls -S /build/images/*.tar); do
	docker load --input "${image}"
done

# Tag the Supervisor how the OS expects it to be tagged
supervisor=$(docker images --filter "label=io.hass.type=supervisor" --quiet)
arch=$(docker inspect --format '{{ index .Config.Labels "io.hass.arch" }}' "${supervisor}")
docker tag "${supervisor}" "ghcr.io/home-assistant/${arch}-hassio-supervisor:latest"

# Ensure the Hevea add-on images are tagged correctly for offline installation
# Images were loaded from *.tar files (downloaded by hevea-gateway package)
for addon in gateway hassio-access-point hassio-openvpn; do
    if [ -f "/build/images/${addon}.tar" ]; then
        echo "Tagging Hevea add-on image: ${addon}..."
        # Find the image by its repository name
        img=$(docker images --filter "reference=ghcr.io/hevea-project/${addon}*" --format "{{.Repository}}:{{.Tag}}" | head -1)
        if [ -z "${img}" ]; then
            # Try to find by label if reference doesn't match
            img_id=$(docker images --filter "label=org.opencontainers.image.source=https://github.com/hevea-project/${addon}" --format "{{.ID}}" | head -1)
            if [ -n "${img_id}" ]; then
                docker tag "${img_id}" "ghcr.io/hevea-project/${addon}:1.0.0"
            fi
        fi
        # Also tag as latest for compatibility
        if docker images --filter "reference=ghcr.io/hevea-project/${addon}:1.0.0" --quiet | grep -q .; then
            docker tag "ghcr.io/hevea-project/${addon}:1.0.0" "ghcr.io/hevea-project/${addon}:latest"
        fi
    fi
done
