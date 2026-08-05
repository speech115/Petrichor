#!/usr/bin/env bash
# Copy a local folder into Petrichor's Documents on the connected iPhone.
#
# Replaces the Finder drag-and-drop step: devicectl can write straight into the
# app data container, so loading test material is scriptable.
#
# Usage: push-music.sh <local-folder> [remote-subpath]
#        remote-subpath defaults to Documents/<folder-name>
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

source_dir=${1:?Usage: push-music.sh <local-folder> [remote-subpath]}
[[ -d "$source_dir" ]] || { echo "Not a directory: $source_dir" >&2; exit 1; }

source_dir=$(cd "$source_dir" && pwd)
destination=${2:-"Documents/$(basename "$source_dir")"}

device=$("$here/device-id.sh")

# --remove-existing-content is deliberately never passed: it wipes the
# destination directory, and the destination here is the real library.
echo "→ $source_dir  ⇒  $destination on $device"
xcrun devicectl device copy to \
  --device "$device" \
  --domain-type appDataContainer \
  --domain-identifier org.Petrichor.ios \
  --source "$source_dir" \
  --destination "$destination"

echo
echo "Copied. Rescan the library in the app to pick the files up."
echo "Note: devicectl cannot delete — anything pushed stays until the app is removed."
