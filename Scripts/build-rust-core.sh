#!/bin/bash
# Builds the Rust core (rust/) for the macOS app into rust/build/:
# PetrichorCoreFFI.xcframework (universal arm64 + x86_64) plus the UniFFI
# Swift bindings that the local `PetrichorCore` package wraps.
# Run once after checkout and after every change under rust/src.
set -euo pipefail

cd "$(dirname "$0")/../rust"
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"

TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
LIB=libpetrichor_core.a
OUT=build

rustup target add "${TARGETS[@]}" >/dev/null
for target in "${TARGETS[@]}"; do
    cargo build --release --target "$target"
done

rm -rf "$OUT"
mkdir -p "$OUT/headers" "$OUT/swift" "$OUT/universal"
# uniffi reads the exported API from a built library.
cargo run --release --bin uniffi-bindgen -- generate \
    --library "target/aarch64-apple-darwin/release/libpetrichor_core.dylib" \
    --language swift --out-dir "$OUT/generated"
mv "$OUT/generated/"*.swift "$OUT/swift/"
python3 ../Scripts/optimize-uniffi-swift-readers.py "$OUT/swift/petrichor_core.swift"
mv "$OUT/generated/"*.h "$OUT/headers/"
mv "$OUT/generated/"*.modulemap "$OUT/headers/module.modulemap"
rm -rf "$OUT/generated"

libs=()
for target in "${TARGETS[@]}"; do
    libs+=("target/$target/release/$LIB")
done
lipo -create "${libs[@]}" -output "$OUT/universal/$LIB"
xcodebuild -create-xcframework \
    -library "$OUT/universal/$LIB" -headers "$OUT/headers" \
    -output "$OUT/PetrichorCoreFFI.xcframework" >/dev/null
rm -rf "$OUT/universal"
echo "Built $(pwd)/$OUT"
