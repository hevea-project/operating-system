#!/bin/bash
set -euo pipefail

HEVEA_REPO_NAME="Hevea Apps"
HEVEA_REPO_URL="https://github.com/hevea-project/hassio-apps"
BOOTSTRAP_MARKER="/etc/hevea-bootstrap.complete"

# ── Reusable function ───────────────────────────────────────────────
get_hevea_repo_slug() {
  local json
  json=$(ha store --raw-json)
  local slug
  slug=$(echo "$json" | jq -r '.data.repositories[] | select(.name == "Hevea Apps") | .slug')
  if [ -z "$slug" ] || [ "$slug" = "null" ]; then
    echo "error: could not find Hevea Apps repository slug" >&2
    return 1
  fi
  echo "$slug"
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

# ── Main ────────────────────────────────────────────────────────────
echo "=== Hevea Bootstrap ==="

# Get the slug for Hevea Apps repository
HEVEA_REPO_SLUG=$(get_hevea_repo_slug)

# Add the Hevea store repository if not already present
echo "Adding Hevea store repository..."
if ha store --raw-json | jq -e ".data.repositories[] | select(.name == \"$HEVEA_REPO_NAME\")" >/dev/null 2>&1; then
  echo "Repository '$HEVEA_REPO_NAME' already exists, skipping."
else
  ha store add "$HEVEA_REPO_URL" "$HEVEA_REPO_NAME"
fi

# Install the three required addons
echo "Installing Hevea addons..."

for addon in "Hevea Access Point" "Hevea Onboarding App" "Hevea OpenVPN"; do
  slug=$(addon_slug_from_name "$addon" "$HEVEA_REPO_SLUG")
  echo "Installing add-on: $slug"
  ha store install "$slug" --raw-json >/dev/null 2>&1
done

# Create marker file so systemd won't re-run this on next boot
touch "$BOOTSTRAP_MARKER"
echo "=== Hevea Bootstrap complete ==="
