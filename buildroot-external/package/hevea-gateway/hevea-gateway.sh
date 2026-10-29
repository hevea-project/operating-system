#!/bin/sh
# POSIX sh compatible - HAOS uses BusyBox ash as /bin/sh (no bash arrays)
set -eu

HEVEA_REPO_NAME="Hevea Apps"
HEVEA_REPO_URL="https://github.com/hevea-project/hassio-apps"
# The Supervisor derives the repository slug from the URL (sha1 of the
# lowercased URL, first 8 hex chars): the same URL always yields the same
# slug, on every device. The add-ons are pre-installed in the image under
# this slug (see craft-apps-json.py), so they are the same add-ons as the
# GitHub repository provides and can be updated once it is added.
HEVEA_REPO_SLUG=$(printf '%s' "$HEVEA_REPO_URL" | tr 'A-Z' 'a-z' | sha1sum | cut -c1-8)
BOOTSTRAP_MARKER="/mnt/overlay/etc/hevea-gateway.complete"

# All Hevea add-ons (slug:name pairs, space-separated)
# Format: "slug:name slug:name ..." (slug first, no spaces in slug)
# Note: We use slug:name (not name:slug) because names contain spaces
HEVEA_ADDONS="hassio-gateway:Hevea_Gateway hassio-access-point:Hevea_Access_Point hassio-openvpn:Hevea_OpenVPN_client"

retry_command() {
  local cmd="$1"
  local error_msg="$2"
  local attempts="${3:-6}"
  local i
  for i in $(seq 1 "$attempts"); do
    if eval "$cmd" >/dev/null 2>&1; then
      return 0
    fi
    if [ "$i" -eq "$attempts" ]; then
      echo "❌ $error_msg" >&2
      return 1
    fi
    sleep 10
  done
}

# Whether the GitHub repository is reachable. `ha store add` cannot be used
# to detect this: it succeeds even when the repository clone fails in the
# background.
online() {
  curl -s -o /dev/null -m 8 "$HEVEA_REPO_URL" 2>/dev/null
}

# Print the slug under which an add-on is installed. The Supervisor prefixes
# the slug of add-ons from custom repositories with the repository slug, so
# the same add-on is "<repo>_hassio-gateway". Prints nothing when the add-on
# is not installed.
installed_slug() {
  local slug="$1"
  ha apps --raw-json 2>/dev/null | jq -r --arg slug "$slug" \
    '.data.addons[] | select(.slug == $slug or (.slug | endswith("_" + $slug))) | .slug' \
    | head -1
}

is_addon_installed() {
  [ -n "$(installed_slug "$1")" ]
}

is_addon_running() {
  local slug="$1"
  ha apps --raw-json 2>/dev/null | jq -e --arg slug "$slug" \
    '.data.addons[] | select(.slug == $slug and .state == "started")' >/dev/null 2>&1
}

# Whether the GitHub repository is in the store (checked by slug: the slug
# is derived from the URL, so it is stable even if the repository name or
# its synchronization state differs).
repo_exists() {
  ha store --raw-json 2>/dev/null | jq -e --arg slug "$HEVEA_REPO_SLUG" \
    '.data.repositories[] | select(.slug == $slug)' >/dev/null 2>&1
}

# Whether the repository is synchronized (its add-ons are visible in the
# store and can be installed).
repo_synced() {
  ha store apps --raw-json 2>/dev/null | jq -e --arg slug "$HEVEA_REPO_SLUG" \
    '.data.addons[] | select(.repository == $slug)' >/dev/null 2>&1
}

install_addon() {
  local name="$1"
  local slug="$2"

  # installed_slug also matches the effective (repository-prefixed) slug.
  if is_addon_installed "$slug"; then
    echo "✅ $name already installed"
    return 0
  fi

  echo "🚀 Installing: $name"
  # No --raw-json: with it the CLI exits 0 even when the install fails.
  if ha store apps install "$slug" >/dev/null 2>&1; then
    echo "   ✅ Done"
    return 0
  else
    echo "   ❌ Failed" >&2
    return 1
  fi
}

start_gateway() {
  local gw_slug
  gw_slug=$(installed_slug "hassio-gateway")
  if [ -z "$gw_slug" ]; then
    echo "   ⚠️ Gateway not installed, cannot start" >&2
    return 1
  fi
  if is_addon_running "$gw_slug"; then
    echo "✅ Gateway already running"
    return 0
  fi
  echo "🚀 Starting Hevea Gateway..."
  if ha apps start "$gw_slug" >/dev/null 2>&1; then
    echo "   ✅ Done"
    return 0
  else
    echo "   ❌ Failed" >&2
    return 1
  fi
}

echo "=== Hevea Gateway Bootstrap ==="

echo "⏳ Waiting for Home Assistant Supervisor to start..."
# Wait for the 'ha' command to be available (hassio_cli container is up)
retry_command "ha" "Failed to execute 'ha' after 12 attempts. It might be because the hassio_cli container is not running." 12

# Now wait for the Supervisor itself to be ready. On a first boot the
# Supervisor can take several minutes (slow repository syncs): allow 5 min.
retry_command "ha banner >/dev/null 2>&1" "Failed to reach the Supervisor after 30 attempts. It might still be starting." 30

FAILED=0
REPO_READY=false

# Ensure the GitHub repository is added, so the pre-installed add-ons are
# known to the store and can be updated. Requires internet.
if online; then
  if repo_exists; then
    echo "✅ Repository '$HEVEA_REPO_NAME' already added."
  else
    echo "Adding GitHub repository..."
    ha store add "$HEVEA_REPO_URL" >/dev/null 2>&1 || echo "⚠️ Could not add GitHub repository"
  fi
  if repo_exists; then
    # Wait for the repository to be synchronized (its add-ons visible in
    # the store)
    echo "⏳ Waiting for the repository to sync..."
    i=0
    while [ "$i" -lt 24 ]; do
      if repo_synced; then
        break
      fi
      sleep 5
      i=$((i + 1))
    done
    if [ "$i" -lt 24 ]; then
      REPO_READY=true
      echo "✅ Repository '$HEVEA_REPO_NAME' ready (slug: $HEVEA_REPO_SLUG)."
    else
      echo "⚠️ Repository '$HEVEA_REPO_NAME' did not sync" >&2
    fi
  fi
else
  echo "⚠️ GitHub not reachable (offline mode)"
fi

# The add-ons are pre-installed in the image (baked under the GitHub
# repository slug in the data partition): check whether they are all present.
ALL_INSTALLED=true
for addon_pair in $HEVEA_ADDONS; do
    slug="${addon_pair%%:*}"
    if ! is_addon_installed "$slug"; then
        ALL_INSTALLED=false
        break
    fi
done

if [ "$ALL_INSTALLED" = "true" ]; then
  echo "✅ All Hevea add-ons already installed"
else
  # Repair path: at least one add-on is missing. The Supervisor cannot
  # install add-ons while the host is offline (its install job always pulls
  # the image from the registry), so this requires the GitHub repository.
  if [ "$REPO_READY" != "true" ]; then
    echo "❌ Add-ons missing and the GitHub repository is not available: the Supervisor cannot install add-ons offline" >&2
    exit 1
  fi
  echo "Installing Hevea addons..."
  for addon_pair in $HEVEA_ADDONS; do
    slug="${addon_pair%%:*}"
    name="${addon_pair##*:}"
    # Replace underscores with spaces for display
    name=$(echo "$name" | tr '_' ' ')
    install_addon "$name" "${HEVEA_REPO_SLUG}_${slug}" || FAILED=1
  done
fi

# Start the Hevea Gateway addon
start_gateway || FAILED=1

if [ "$FAILED" -ne 0 ]; then
  echo "❌ Hevea Gateway Bootstrap failed" >&2
  exit 1
fi

if [ "$REPO_READY" = "true" ]; then
  # Create the marker file so systemd won't re-run this on next boot.
  touch "$BOOTSTRAP_MARKER"
  echo "=== Hevea Gateway Bootstrap complete ==="
else
  # Offline first boot: everything works, but the GitHub repository could
  # not be added yet. Do not set the marker: the bootstrap re-runs on the
  # next boots and adds the repository on the first online boot.
  echo "ℹ️ Offline: the GitHub repository will be added on the first online boot"
  echo "=== Hevea Gateway Bootstrap complete (offline, will re-run when online) ==="
fi
