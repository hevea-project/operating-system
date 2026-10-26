#!/bin/bash
set -euo pipefail

HEVEA_REPO_NAME="Hevea Apps"
HEVEA_REPO_URL="https://github.com/hevea-project/hassio-apps"
LOCAL_REPO_PATH="/opt/hevea/addons-repo"
LOCAL_REPO_NAME="Hevea Apps (Local)"
BOOTSTRAP_MARKER="/mnt/overlay/etc/hevea-gateway.complete"

# All Hevea add-ons to install (name:slug pairs)
HEVEA_ADDONS=(
    "Hevea Gateway:hassio-gateway"
    "Hevea Access Point:hassio-access-point"
    "Hevea OpenVPN client:hassio-openvpn"
)

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

addon_slug_from_name() {
  local name="$1"
  local repo_slug="${2:-}"

  local json
  json=$(ha store apps --raw-json)

  local slug
  slug=$(echo "$json" | jq -r --arg name "$name" --arg repo "${repo_slug}" '
    .data.addons
    | map(select(.name == $name))
    | if ($repo | length) > 0 then
        map(select(.repository == $repo))
      else
        .
      end
    | if length == 0 then
        empty
      elif length > 1 then
        error("multiple matches")
      else
        .[0].slug
      end
  ') || {
    echo "error: no add-on or ambiguous match for \"$name\"" >&2
    return 1
  }

  echo "$slug"
}

is_addon_installed() {
  local slug="$1"
  ha apps --raw-json 2>/dev/null | jq -e --arg slug "$slug" \
    '.data.addons[] | select(.slug == $slug)' >/dev/null 2>&1
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
  local repo_slug="$3"

  if is_addon_installed "$slug"; then
    echo "✅ $name already installed"
    return 0
  fi

  echo "🚀 Installing: $name"
  if ha store apps install "$slug" --raw-json >/dev/null 2>&1; then
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
ha banner >/dev/null 2>&1

# Check if all add-ons are already installed (e.g. from a previous boot)
ALL_INSTALLED=true
for addon_pair in "${HEVEA_ADDONS[@]}"; do
    slug="${addon_pair##*:}"
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
  # Start the gateway if not running
  if ! is_addon_running "hassio-gateway"; then
    echo "🚀 Starting Hevea Gateway..."
    ha apps start "hassio-gateway" >/dev/null 2>&1 && echo "   ✅ Done" || echo "   ❌ Failed" >&2
  fi
  touch "$BOOTSTRAP_MARKER"
  echo "=== Hevea Gateway Bootstrap complete ==="
  exit 0
fi

# Add-ons not all installed yet — try online installation first, fall back to offline
ONLINE=false

if repo_exists "$HEVEA_REPO_NAME"; then
  echo "✅ Repository '$HEVEA_REPO_NAME' already exists."
  ONLINE=true
else
  echo "Trying to add GitHub repository..."
  if ha store add "$HEVEA_REPO_URL" >/dev/null 2>&1; then
    echo "✅ Added repository '$HEVEA_REPO_NAME'."
    ONLINE=true
  else
    echo "⚠️ GitHub not reachable (offline mode)"
  fi
fi

if [ "$ONLINE" = "true" ]; then
  # === ONLINE MODE ===
  # Install all add-ons from the GitHub repository
  HEVEA_REPO_SLUG=$(get_repo_slug "$HEVEA_REPO_NAME")
  echo "📦 Using repository: $HEVEA_REPO_NAME (slug: $HEVEA_REPO_SLUG)"

  echo "Installing Hevea addons..."
  for addon_pair in "${HEVEA_ADDONS[@]}"; do
    name="${addon_pair%%:*}"
    slug="${addon_pair##*:}"
    install_addon "$name" "$slug" "$HEVEA_REPO_SLUG" || true
  done
else
  # === OFFLINE MODE ===
  # Temporarily add the local repository, install all add-ons, then remove it.
  # This avoids conflicts with the GitHub repository when the device comes online.
  echo "📦 Using local repository (temporary, offline mode)"

  if [ ! -d "$LOCAL_REPO_PATH" ]; then
    echo "❌ Local repository not found at $LOCAL_REPO_PATH" >&2
    exit 1
  fi

  # Add the local repository temporarily
  if ! ha store add "$LOCAL_REPO_PATH" >/dev/null 2>&1; then
    echo "❌ Failed to add local repository" >&2
    exit 1
  fi
  echo "✅ Added local repository temporarily"

  # Get the local repository slug
  LOCAL_REPO_SLUG=$(get_repo_slug "$LOCAL_REPO_NAME")
  if [ -z "$LOCAL_REPO_SLUG" ] || [ "$LOCAL_REPO_SLUG" = "null" ]; then
    echo "❌ Could not find local repository slug" >&2
    exit 1
  fi

  # Install all add-ons from the local repository
  # The images are pre-loaded in Docker, so no network pull is needed
  echo "Installing Hevea addons (offline)..."
  for addon_pair in "${HEVEA_ADDONS[@]}"; do
    name="${addon_pair%%:*}"
    slug="${addon_pair##*:}"
    install_addon "$name" "$slug" "$LOCAL_REPO_SLUG" || true
  done

  # Remove the local repository to avoid conflicts with GitHub later
  echo "🗑️  Removing local repository (avoiding future conflicts)..."
  if ha store remove "$LOCAL_REPO_SLUG" >/dev/null 2>&1; then
    echo "   ✅ Removed"
  else
    echo "   ⚠️ Could not remove local repository" >&2
  fi

  # Note: The add-ons stay installed even after the repository is removed.
  # The Supervisor keeps add-on data in /data/addons/data/<slug>/.
fi

# Start the Hevea Gateway addon
echo "🚀 Starting Hevea Gateway addon..."
if is_addon_installed "hassio-gateway"; then
  if ha apps start "hassio-gateway" >/dev/null 2>&1; then
    echo "   ✅ Done"
  else
    echo "   ❌ Failed" >&2
  fi
else
  echo "   ⚠️ Gateway not installed, cannot start" >&2
fi

# Create marker file so systemd won't re-run this on next boot
touch "$BOOTSTRAP_MARKER"
echo "=== Hevea Gateway Bootstrap complete ==="
