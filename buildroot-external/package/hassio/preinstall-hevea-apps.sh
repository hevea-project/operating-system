#!/usr/bin/env bash
# Bake the Hevea add-ons pre-install state into the data partition.
#
# The Supervisor cannot install add-ons while the host is offline (its
# install job always pulls the image from the registry), so the add-ons are
# baked as already installed:
# - apps/data/<slug>: the add-ons data directories
# - apps.json: the installed-apps state (crafted by the hevea-gateway
#   package under the GitHub repository slug, so the add-ons are the same as
#   the GitHub repository provides and can be updated once it is added)
#
# Usage: preinstall-hevea-apps.sh <hevea-gateway images dir> <data partition mount point>
set -e

imgdir=$1
data_dir=$2

apps_json="${imgdir}/apps.json"

if [ ! -f "${apps_json}" ]; then
    echo "No Hevea pre-install state in ${imgdir}, skipping"
    exit 0
fi

echo "Baking Hevea add-ons pre-install state"
mkdir -p "${data_dir}/supervisor/apps/data"
# The installed slug is "<repo-slug>_<addon>" (see the apps.json keys)
for key in $(jq -r '.system | keys[]' "${apps_json}"); do
    mkdir -p "${data_dir}/supervisor/apps/data/${key}"
done
cp "${apps_json}" "${data_dir}/supervisor/apps.json"
