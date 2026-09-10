#!/usr/bin/env bash
# Build PetrichoriOS for a generic iOS device and install it on the connected
# iPhone through devicectl.
#
# The generic destination is the point: Xcode 26.6 cannot mount a Developer Disk
# Image for iOS 27 beta, so any destination naming the actual device fails before
# compiling. Signing and installation do not need the DDI, so this path works.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../../../.." && pwd)

configuration=Debug
launch=true
console=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)   configuration=Release ;;
    --no-launch) launch=false ;;
    --console)   console=true ;;
    -h|--help)   sed -n '2,9p' "$0"; exit 0 ;;
    *)           echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

run() { echo "→ $*"; "$@"; }

device=$("$here/device-id.sh")
echo "Device: $device"

cd "$repo"

run xcodebuild -scheme PetrichoriOS \
  -destination 'generic/platform=iOS' \
  -configuration "$configuration" \
  -allowProvisioningUpdates \
  build

# Ask xcodebuild where it put the bundle rather than hardcoding the DerivedData
# hash, which changes whenever the project is re-created or DerivedData is cleaned.
settings=$(xcodebuild -scheme PetrichoriOS \
  -destination 'generic/platform=iOS' \
  -configuration "$configuration" \
  -showBuildSettings 2>/dev/null)

products_dir=$(awk -F' = ' '/^ +BUILT_PRODUCTS_DIR = /{print $2; exit}' <<<"$settings")
product_name=$(awk -F' = ' '/^ +FULL_PRODUCT_NAME = /{print $2; exit}' <<<"$settings")
bundle_id=$(awk -F' = ' '/^ +PRODUCT_BUNDLE_IDENTIFIER = /{print $2; exit}' <<<"$settings")
app="$products_dir/$product_name"

[[ -d "$app" ]] || { echo "Built product not found at $app" >&2; exit 1; }

run xcrun devicectl device install app --device "$device" "$app"

if [[ "$launch" == true ]]; then
  args=(--device "$device" --terminate-existing)
  [[ "$console" == true ]] && args+=(--console)
  run xcrun devicectl device process launch "${args[@]}" "$bundle_id"
fi
