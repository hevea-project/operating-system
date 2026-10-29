#!/bin/sh
# POSIX sh compatible - HAOS uses BusyBox ash as /bin/sh (no bash arrays)
set -eu

HEVEA_REPO_NAME="Hevea Apps"
HEVEA_REPO_URL="https://github.com/hevea-project/hassio-apps"
# /usr/share (not /opt): the HAOS post-build cleanup (fix_rootfs) removes
# the whole /opt directory from the target rootfs. Overridable for tests.
LOCAL_APPS_SRC="${HEVEA_LOCAL_APPS_SRC:-/usr/share/hevea/addons-repo}"
# The Supervisor always serves a built-in "local" repository scanning this
# directory (the Supervisor /data is /mnt/data/supervisor on the host). The
# Supervisor cannot add a plain directory as a repository (it expects a git
# URL), so the offline fallback copies the add-on definitions there instead.
# Overridable for tests.
LOCAL_APPS_DIR="${HEVEA_LOCAL_APPS_DIR:-/mnt/data/supervisor/apps/local}"
BOOTSTRAP_MARKER="/mnt/overlay/etc/hevea-gateway.complete"

# All Hevea add-ons to install (slug:name pairs, space-separated)
# Format: "slug:name slug:name ..." (slug first, no spaces in slug)
# Note: We use slug:name (not name:slug) because names contain spaces
HEVEA_ADDONS="hassio-gateway:Hevea_Gateway hassio-access-point:Hevea_Access_Point hassio-openvpn:Hevea_OpenVPN_client"

retry_command() {
  local cmd="$1"
  local error_msg="$2"
  for i in 1 2 3 4 5 6; do
    if eval "$cmd" >/dev/null 2>&1; then
      return 0
    fi
    if [ "$i" -eq 6 ]; then
      echo "❌ $error_msg" >&2
      return 1
    fi
    sleep 10
  done
}

get_repo_slug() {
  local name="$1"
  ha store --raw-json 2>/dev/null | jq -r --arg name "$name" \
    '.data.repositories[] | select(.name == $name) | .slug'
}

# Print the slug under which an add-on is installed. The Supervisor prefixes
# the slug of add-ons from custom repositories with the repository slug, so
# the same add-on is "<repo>_hassio-gateway" from the GitHub repository and
# "local_hassio-gateway" from the local repository. Prints nothing when the
# add-on is not installed.
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

repo_exists() {
  local name="$1"
  ha store --raw-json 2>/dev/null | jq -e --arg name "$name" \
    '.data.repositories[] | select(.name == $name)' >/dev/null 2>&1
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
retry_command "ha" "Failed to execute 'ha' after 6 attempts. It might be because the hassio_cli container is not running."

# Now wait for the Supervisor itself to be ready
retry_command "ha banner >/dev/null 2>&1" "Failed to reach the Supervisor after 6 attempts. It might still be starting."

FAILED=0

# Check if all add-ons are already installed (e.g. from a previous boot)
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
  # Ensure the GitHub repository is added for future updates
  if ! repo_exists "$HEVEA_REPO_NAME"; then
    echo "Adding GitHub repository for updates..."
    ha store add "$HEVEA_REPO_URL" >/dev/null 2>&1 || echo "⚠️ Could not add GitHub repository (offline?)"
  fi
  start_gateway || FAILED=1
else
  # Add-ons not all installed yet — try online installation first, fall back to offline
  ONLINE=false
  REPO_SLUG=""

  # `ha store add` succeeds even when the repository clone fails in the
  # background, so it cannot detect the offline mode: check GitHub
  # reachability directly.
  if curl -s -o /dev/null -m 8 "$HEVEA_REPO_URL" 2>/dev/null; then
    if ! repo_exists "$HEVEA_REPO_NAME"; then
      echo "Adding GitHub repository..."
      ha store add "$HEVEA_REPO_URL" >/dev/null 2>&1 || echo "⚠️ Could not add GitHub repository"
    fi
    if repo_exists "$HEVEA_REPO_NAME"; then
      REPO_SLUG=$(get_repo_slug "$HEVEA_REPO_NAME")
      # Wait for the repository to be synced (its add-ons visible in the store)
      echo "⏳ Waiting for the repository to sync..."
      i=0
      while [ "$i" -lt 24 ]; do
        if ha store apps --raw-json 2>/dev/null | jq -e --arg slug "$REPO_SLUG" \
            '.data.addons[] | select(.repository == $slug)' >/dev/null 2>&1; then
          break
        fi
        sleep 5
        i=$((i + 1))
      done
      if [ "$i" -lt 24 ]; then
        ONLINE=true
        echo "✅ Repository '$HEVEA_REPO_NAME' ready (slug: $REPO_SLUG)."
      else
        echo "⚠️ Repository '$HEVEA_REPO_NAME' did not sync (offline?)"
      fi
    fi
  else
    echo "⚠️ GitHub not reachable (offline mode)"
  fi

  if [ "$ONLINE" = "true" ]; then
    # === ONLINE MODE ===
    # Install all add-ons from the GitHub repository
    echo "📦 Using repository: $HEVEA_REPO_NAME (slug: $REPO_SLUG)"

    echo "Installing Hevea addons..."
    for addon_pair in $HEVEA_ADDONS; do
      slug="${addon_pair%%:*}"
      name="${addon_pair##*:}"
      # Replace underscores with spaces for display
      name=$(echo "$name" | tr '_' ' ')
      install_addon "$name" "${REPO_SLUG}_${slug}" || FAILED=1
    done
  else
    # === OFFLINE MODE ===
    # The Supervisor cannot add a plain directory as a repository (it expects
    # a git URL), but it always serves the built-in "local" repository which
    # scans the local apps directory: copy the add-on definitions there and
    # reload the store. The add-on images are pre-loaded in Docker (see the
    # hevea-gateway buildroot package), so no network pull is needed.
    echo "📦 Using local apps directory (offline mode)"

    if [ ! -d "$LOCAL_APPS_SRC" ]; then
      echo "❌ Local add-ons not found at $LOCAL_APPS_SRC" >&2
      exit 1
    fi

    mkdir -p "$LOCAL_APPS_DIR"
    for addon_pair in $HEVEA_ADDONS; do
      slug="${addon_pair%%:*}"
      rm -rf "$LOCAL_APPS_DIR/$slug"
      cp -r "$LOCAL_APPS_SRC/$slug" "$LOCAL_APPS_DIR/$slug"
    done
    ha store reload >/dev/null 2>&1 || echo "⚠️ Could not reload the store" >&2

    echo "Installing Hevea addons (offline)..."
    for addon_pair in $HEVEA_ADDONS; do
      slug="${addon_pair%%:*}"
      name="${addon_pair##*:}"
      # Replace underscores with spaces for display
      name=$(echo "$name" | tr '_' ' ')
      install_addon "$name" "local_${slug}" || FAILED=1
    done
  fi

  # Start the Hevea Gateway addon
  start_gateway || FAILED=1
fi

# Create the marker file only on success, so systemd re-runs this service on
# the next boot when the installation failed.
if [ "$FAILED" -eq 0 ]; then
  touch "$BOOTSTRAP_MARKER"
  echo "=== Hevea Gateway Bootstrap complete ==="
else
  echo "❌ Hevea Gateway Bootstrap failed" >&2
  exit 1
fi
