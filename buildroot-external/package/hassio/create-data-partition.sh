#!/usr/bin/env bash
set -e

build_dir=$1
dst_dir=$2
channel=$3
docker_version=$4

data_img="${dst_dir}/data.ext4"
data_dir="${build_dir}/data"

APPARMOR_URL="https://chezbob.glumol.com/hevea/apparmor_${channel}.txt"

# Hevea add-ons preload: image tarballs location (downloaded by hevea-gateway package)
HEVEA_IMGDIR="${dst_dir}/hevea-gateway"

# Copy all Hevea add-on images to build_dir/images so dind-import-containers.sh picks them up
if [ -d "${HEVEA_IMGDIR}" ]; then
    echo "Embedding Hevea add-on images from: ${HEVEA_IMGDIR}"
    mkdir -p "${build_dir}/images"
    cp "${HEVEA_IMGDIR}"/*.tar "${build_dir}/images/"
fi

# Make image
rm -f "${data_img}"
truncate --size="1280M" "${data_img}"
mkfs.ext4 -L "hassos-data" -E lazy_itable_init=0,lazy_journal_init=0 "${data_img}"

# Mount / init file structs
mkdir -p "${data_dir}"
sudo mount -o loop,discard "${data_img}" "${data_dir}"

trap 'docker rm -f ${container} > /dev/null; sudo umount ${data_dir} || true' ERR EXIT

# Use official Docker in Docker images
# We use the same version as Buildroot is using to ensure best compatibility
container=$(docker run --privileged -e DOCKER_TLS_CERTDIR="" \
    -v "${data_dir}":/mnt/data \
    -v "${build_dir}":/build \
    -d "docker:${docker_version}-dind" --feature containerd-snapshotter --data-root /mnt/data/docker)

docker exec "${container}" sh /build/dind-import-containers.sh

# Bake the Hevea add-ons pre-install state into the data partition (see
# preinstall-hevea-apps.sh). Runs outside the heredoc below: the heredoc is
# unquoted, so the outer shell would expand any shell variable used inside.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
sudo "${SCRIPT_DIR}/preinstall-hevea-apps.sh" "${HEVEA_IMGDIR}" "${data_dir}"

sudo bash -ex <<EOF
# Indicator for docker-prepare.service to use the containerd snapshotter
touch "${data_dir}/.docker-use-containerd-snapshotter"

# Setup AppArmor
mkdir -p "${data_dir}/supervisor/apparmor"
curl -fsL -o "${data_dir}/supervisor/apparmor/hassio-supervisor" "${APPARMOR_URL}"

# Persist build-time updater channel
jq -n --arg channel "${channel}" '{"channel": \$channel}' > "${data_dir}/supervisor/updater.json"
EOF

# Tear down docker and unmount the data partition before shrinking
docker rm -f "${container}" > /dev/null
sudo umount "${data_dir}"
trap - ERR EXIT

# Shrink the filesystem to its minimum size
e2fsck -f -y "${data_img}"
resize2fs -M "${data_img}"

# Truncate image file to match the filesystem size
block_count=$(dumpe2fs -h "${data_img}" 2>/dev/null | awk '/^Block count:/{print $3}')
block_size=$(dumpe2fs -h "${data_img}" 2>/dev/null | awk '/^Block size:/{print $3}')
truncate --size="$((block_count * block_size))" "${data_img}"
