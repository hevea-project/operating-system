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

# "running" includes "starting": the Supervisor starts boot=auto add-ons by
# itself at boot, and a start requested while one is already in progress is
# rejected — that is not a failure.
is_addon_running() {
  local slug="$1"
  ha apps --raw-json 2>/dev/null | jq -e --arg slug "$slug" \
    '.data.addons[] | select(.slug == $slug and (.state == "started" or .state == "starting"))' >/dev/null 2>&1
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
  local i
  for i in 1 2 3 4 5; do
    if ha apps start "$gw_slug" >/dev/null 2>&1; then
      echo "   ✅ Done"
      return 0
    fi
    # A rejected start is not a failure if the add-on ends up running (the
    # Supervisor may be starting it by itself, see is_addon_running).
    sleep 10
    if is_addon_running "$gw_slug"; then
      echo "   ✅ Done (already starting)"
      return 0
    fi
  done
  echo "   ❌ Failed" >&2
  return 1
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
# known to the store and can be updated. Requires internet. At first boot
# this script can run before the network (DHCP/DNS) or the Supervisor
# plugins are ready, so retry the reachability check, the add and the sync
# for a while before giving up (the bootstrap re-runs on the next boots
# anyway when the marker is not set).
REPO_READY=false
attempt=0
while [ "$attempt" -lt 5 ]; do
  attempt=$((attempt + 1))
  if ! online; then
    sleep 5
    continue
  fi
  if ! repo_exists; then
    echo "Adding GitHub repository... (attempt $attempt)"
    ha store add "$HEVEA_REPO_URL" >/dev/null 2>&1 || echo "⚠️ Could not add GitHub repository (attempt $attempt)"
  fi
  if repo_exists; then
    echo "⏳ Waiting for the repository to sync..."
    i=0
    while [ "$i" -lt 12 ]; do
      if repo_synced; then
        break
      fi
      sleep 5
      i=$((i + 1))
    done
    if [ "$i" -lt 12 ]; then
      REPO_READY=true
      echo "✅ Repository '$HEVEA_REPO_NAME' ready (slug: $HEVEA_REPO_SLUG)."
      break
    fi
    echo "⚠️ Repository '$HEVEA_REPO_NAME' not synced yet (attempt $attempt)" >&2
  fi
  sleep 10
done
if [ "$REPO_READY" != "true" ]; then
  if online; then
    echo "⚠️ GitHub repository not ready yet, will retry on the next boot"
  else
    echo "⚠️ GitHub not reachable (offline mode)"
  fi
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

# --- Official add-ons (pre-installed under the built-in "core" slug) -------
OTBR_SLUG="core_openthread_border_router"
MATTER_SLUG="core_matter_server"

# Stable device path of the Thread USB dongle (a USB serial running the
# OpenThread RCP firmware: ESP32-C6 enumerates as an Espressif gadget, the
# nRF52840 as "usb-Nordic_Semiconductor_nRF528xx_OpenThread_Device", Silicon
# Labs as SL_OpenThread...). Prefer the /dev/serial/by-id symlink, then the
# first ttyACM/ttyUSB. The dongle may not be enumerated yet when the
# bootstrap runs early at boot, so wait a few seconds for it to appear.
detect_thread_dongle() {
  local d i
  for i in $(seq 1 15); do
    for d in /dev/serial/by-id/*Espressif* /dev/serial/by-id/*ESP32* \
             /dev/serial/by-id/*Nordic* /dev/serial/by-id/*nRF* \
             /dev/serial/by-id/*OpenThread* /dev/serial/by-id/*SL_OpenThread* /dev/serial/by-id/*SL_Openthread* \
             /dev/serial/by-id/*Silicon_Labs* /dev/serial/by-id/*Texas_Instruments* \
             /dev/serial/by-id/*usb-serial* /dev/serial/by-id/*USB_Serial*; do
      [ -e "$d" ] && { echo "$d"; return 0; }
    done
    for d in /dev/ttyACM* /dev/ttyUSB*; do
      [ -e "$d" ] && { echo "$d"; return 0; }
    done
    sleep 1
  done
  return 1
}

# Configure the OpenThread Border Router add-on with the dongle device and
# start it. The Supervisor API has no partial options update, so the full
# options object is read, merged with the device, and pushed back. The token
# is read from hassio_cli and the API is called inside hassio_supervisor.
# Non-fatal: a missing dongle or a missing add-on must not fail the bootstrap.
configure_otbr() {
  if ! is_addon_installed "openthread_border_router"; then
    echo "ℹ️ $OTBR_SLUG not installed, skipping OpenThread Border Router"
    return 0
  fi
  local device tok opts
  if ! device=$(detect_thread_dongle); then
    echo "ℹ️ No Thread USB dongle detected, skipping OpenThread Border Router"
    return 0
  fi
  echo "🔌 Thread dongle detected: $device"
  tok=$(docker exec hassio_cli sh -c 'echo $SUPERVISOR_TOKEN' 2>/dev/null)
  if [ -z "$tok" ]; then
    echo "⚠️ Could not read the Supervisor token, skipping OTBR configuration" >&2
    return 0
  fi
  # backbone_interface: the uplink interface (default route device, e.g.
  # end0) — without it otbr-agent refuses to start ("No primary network
  # interface found").
  local bb
  bb=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
  [ -n "$bb" ] || bb="end0"
  # The Supervisor API can be busy right after boot (add-on restore jobs),
  # so retry the read and the write a few times before giving up.
  opts=""
  i=0
  while [ $i -lt 5 ]; do
    opts=$(docker exec hassio_supervisor sh -c \
      "curl -s -H \"Authorization: Bearer $tok\" http://localhost/addons/$OTBR_SLUG/info" 2>/dev/null \
      | jq --arg dev "$device" --arg bb "$bb" '{options: (.data.options + {device: $dev, backbone_interface: $bb})}')
    [ -n "$opts" ] && [ "$opts" != "null" ] && break
    i=$((i + 1)); sleep 5
  done
  if [ -z "$opts" ] || [ "$opts" = "null" ]; then
    echo "⚠️ Could not read $OTBR_SLUG options, skipping" >&2
    return 0
  fi
  echo "⚙️ Configuring $OTBR_SLUG with device=$device"
  posted=false
  i=0
  while [ $i -lt 5 ]; do
    if docker exec hassio_supervisor sh -c \
        "curl -s -X POST -H \"Authorization: Bearer $tok\" -H \"Content-Type: application/json\" -d '$opts' http://localhost/addons/$OTBR_SLUG/options" 2>/dev/null \
        | jq -e '.result == "ok"' >/dev/null 2>&1; then
      posted=true; break
    fi
    i=$((i + 1)); sleep 5
  done
  if [ "$posted" != true ]; then
    echo "⚠️ Could not set $OTBR_SLUG options" >&2
    return 0
  fi
  # Verify the device option was applied (read it back)
  local applied
  applied=$(docker exec hassio_supervisor sh -c \
    "curl -s -H \"Authorization: Bearer $tok\" http://localhost/addons/$OTBR_SLUG/info" 2>/dev/null \
    | jq -r '.data.options.device // empty')
  if [ "$applied" != "$device" ]; then
    echo "⚠️ $OTBR_SLUG device option not applied (got '${applied:-none}', expected '$device')" >&2
  fi
  # Options only apply on (re)start
  if is_addon_running "$OTBR_SLUG"; then
    ha apps restart "$OTBR_SLUG" >/dev/null 2>&1 || true
  else
    local i
    for i in 1 2 3; do
      ha apps start "$OTBR_SLUG" >/dev/null 2>&1 && break
      sleep 5
    done
  fi
  if is_addon_running "$OTBR_SLUG"; then
    echo "✅ OpenThread Border Router running (device: $device)"
  else
    echo "⚠️ OpenThread Border Router configured but not running yet (device: $device)" >&2
  fi
  return 0
}

for core_addon in openthread_border_router matter_server; do
  if is_addon_installed "$core_addon"; then
    echo "✅ Official add-on $core_addon pre-installed"
  else
    echo "⚠️ Official add-on $core_addon not installed (offline repair impossible, it will install on the first online boot)"
  fi
done

configure_otbr
# The Matter server needs no first-boot configuration (network-only,
# boot: auto): the Supervisor starts it by itself once installed.

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
