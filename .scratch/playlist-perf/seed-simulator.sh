#!/bin/bash
# Ticket 01: seed the booted iOS simulator with a 1500-track library and a
# 1200-track "big" playlist for the [PERF-0808] before/after measurements.
#
# Repeatable scenario: generate -> push into the app container -> the app's
# reconciliation scans Documents and auto-imports Petrichor-Playlists/big.m3u
# on next launch (iOS/LibraryReconciliation.swift).
#
# Usage:
#   ./seed-simulator.sh [output-dir]
#   (output-dir defaults to ~/scratch/perf-library; simulator must be booted)
#
# For a clean repeat: uninstall the app first (erase its Documents and DB),
# then re-run this script, then build_run_sim.
set -euo pipefail

BUNDLE_ID="org.Petrichor.ios"
OUT_DIR="${1:-$HOME/scratch/perf-library}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Generating 1500 mp3s + big.m3u into $OUT_DIR"
swift "$SCRIPT_DIR/generate-library.swift" "$OUT_DIR"

# `simctl push` is for push notifications, not files. The app container of a
# booted simulator lives on the host filesystem, so copying into it directly
# is the reliable route.
DATA_DIR="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data)"
echo "==> Copying Music/ into $DATA_DIR/Documents/Music/"
rm -rf "$DATA_DIR/Documents/Music"
cp -R "$OUT_DIR/Music" "$DATA_DIR/Documents/Music"

echo "==> Copying Petrichor-Playlists/ into Documents/Petrichor-Playlists/"
rm -rf "$DATA_DIR/Documents/Petrichor-Playlists"
cp -R "$OUT_DIR/Petrichor-Playlists" "$DATA_DIR/Documents/Petrichor-Playlists"

echo "==> Done. Launch the app (build_run_sim): it scans Documents and"
echo "    auto-imports big.m3u. Then open the 'big' playlist. (The"
echo "    [PERF-0808] signpost instrumentation was removed in ticket 08.)"
