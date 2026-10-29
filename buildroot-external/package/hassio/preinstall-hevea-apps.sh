#!/usr/bin/env bash
# Bake the Hevea add-ons pre-install state into the data partition.
#
# The Supervisor cannot install add-ons while the host is offline (its
# install job always pulls the image from the registry), so the add-ons are
# baked as already installed:
# - apps/local: the add-on definitions (the Supervisor built-in "local"
#   repository scans this directory, so the add-ons are known to the store)
# - apps/data/<slug>: the add-ons data directories
# - apps.json: the installed-apps state (crafted by the hevea-gateway package)
#
# Usage: preinstall-hevea-apps.sh <hevea-gateway images dir> <data partition mount point>
set -e

imgdir=$1
data_dir=$2

repo_dir="${imgdir}/addons-repo"
apps_json="${imgdir}/apps.json"

if [ ! -d "${repo_dir}" ] || [ ! -f "${apps_json}" ]; then
    echo "No Hevea pre-install state in ${imgdir}, skipping"
    exit 0
fi

echo "Baking Hevea add-ons pre-install state"
mkdir -p "${data_dir}/supervisor/apps/local" "${data_dir}/supervisor/apps/data"
for addon_dir in "${repo_dir}"/*/; do
    addon="$(basename "${addon_dir}")"
    cp -r "${addon_dir}" "${data_dir}/supervisor/apps/local/${addon}"
    mkdir -p "${data_dir}/supervisor/apps/data/local_${addon}"
done
cp "${apps_json}" "${data_dir}/supervisor/apps.json"
