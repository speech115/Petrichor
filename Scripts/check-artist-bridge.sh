#!/bin/bash
# Run after build-rust-core.sh on macOS; exercises the real Swift/Rust cache seam.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/petrichor-bridge.XXXXXX")
trap 'rm -rf "$work"' EXIT
swiftc -O -emit-library -emit-module -module-name PetrichorCore \
    -I rust/build/headers rust/build/swift/petrichor_core.swift \
    rust/build/PetrichorCoreFFI.xcframework/macos-arm64_x86_64/libpetrichor_core.a \
    -emit-module-path "$work/PetrichorCore.swiftmodule" \
    -o "$work/libPetrichorCore.dylib"
swiftc -Onone -g -swift-version 6 -I "$work" -I rust/build/headers \
    -L "$work" -lPetrichorCore -Xlinker -rpath -Xlinker "$work" \
    Core/ArtistParser.swift rust/tests/artist_bridge/main.swift -o "$work/check"
"$work/check"
