#!/usr/bin/env bash
# Patch the Supervisor image tar: the update-server URL is compiled into the
# Supervisor (URL_HASSIO_VERSION / URL_HASSIO_APPARMOR in const.py), so without
# this patch the runtime OS/add-on update checks go to version.home-assistant.io
# and the update offer comes from the official server. Replace the base URL
# with the Hevea update server: the version.json (which also carries the "ota"
# bundle URL) is then fetched from there.
#
# Usage: patch-supervisor-image.sh <images dir> <hevea version url> <arch>
set -euo pipefail

images_dir=$1
version_url=$2 # e.g. https://chezbob.glumol.com/hevea/
arch=$3

tar_file=$(ls "${images_dir}" | grep 'hassio-supervisor' | head -1 || true)
if [ -z "${tar_file}" ]; then
    echo "no supervisor image tar in ${images_dir}, skipping patch"
    exit 0
fi
tar_path="${images_dir}/${tar_file}"

docker load --input "${tar_path}" >/dev/null
img=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "hassio-supervisor" | head -1)
if [ -z "${img}" ]; then
    echo "supervisor image not found after load, skipping patch" >&2
    exit 1
fi

cid=$(docker create "${img}")
trap 'docker rm -f "${cid}" >/dev/null 2>&1 || true' EXIT
docker cp "${cid}:/usr/src/supervisor/supervisor/const.py" /tmp/const.py.$$
sed -i "s|https://version.home-assistant.io/|${version_url}|g" /tmp/const.py.$$
docker cp /tmp/const.py.$$ "${cid}:/usr/src/supervisor/supervisor/const.py"
rm -f /tmp/const.py.$$
docker commit "${cid}" "${img}" >/dev/null
docker save -o "${tar_path}.patched" "${img}"
mv "${tar_path}.patched" "${tar_path}"
echo "patched supervisor image ${img}: update server -> ${version_url}"
