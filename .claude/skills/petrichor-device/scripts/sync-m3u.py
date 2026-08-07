#!/usr/bin/env python3
"""Rewrite the mac's M3U playlists against the phone's actual filenames and
push them into Petrichor's Documents.

Why: the phone library was renamed during transfer (numeric prefixes stripped,
`,` → `;`, extra tags appended), so an M3U written against the original mac
names matches almost nothing on import. File *size* survives renaming, so:

    mac name (from M3U) → mac file size → phone filename (same size)

Each M3U entry whose size maps to exactly one phone file becomes
`Music/<phone filename>.mp3`; ambiguous or unresolvable entries keep their
original line and simply stay missing from the playlist (design: a missing
file never removes a track position).

Usage: sync-m3u.py [mac-music-folder]
Requires: connected iPhone (devicectl), sqlite3, and read access to the mac
music folder (default: the folder the M3U paths point into). The app
re-imports the rewritten playlists on its next reconciliation (their mtimes
changed).

The import on the phone additionally matches renamed files by normalized
filename (Utilities/M3UFilenameNormalizer.swift); this script instead has
access to the mac's original files, so it resolves by *size* — the rename
that defeated filename matching never touches a file's bytes.
"""
import os
import sqlite3
import subprocess
import sys

DEVICE_ID_CMD = os.path.join(os.path.dirname(__file__), "device-id.sh")
MAC_PLAYLISTS = os.path.expanduser("~/Music/Petrichor-Playlists")
MAC_MUSIC = sys.argv[1] if len(sys.argv) > 1 else \
    "/Users/sereja/Documents/Медиа (музыка:видео:изображения/Моя музыка"
TMP = "/tmp/petrichor-m3u-sync"

def sh(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True)

def main():
    os.makedirs(TMP, exist_ok=True)
    device = sh(DEVICE_ID_CMD).stdout.strip()

    print("→ pulling phone database")
    sh("xcrun", "devicectl", "device", "copy", "from",
       "--device", device,
       "--domain-type", "appDataContainer",
       "--domain-identifier", "org.Petrichor.ios",
       "--source", "Library/Application Support/org.Petrichor.ios/petrichor.db",
       "--destination", f"{TMP}/petrichor.db")

    con = sqlite3.connect(f"{TMP}/petrichor.db")
    phone_size_to_paths = {}
    for size, path in con.execute("SELECT file_size, path FROM tracks"):
        phone_size_to_paths.setdefault(size, []).append(path)
    con.close()

    mac_name_to_sizes = {}
    for dirpath, _, files in os.walk(MAC_MUSIC):
        for name in files:
            if not name.lower().endswith(".mp3"):
                continue
            path = os.path.join(dirpath, name)
            try:
                size = os.path.getsize(path)
            except OSError:
                continue
            mac_name_to_sizes.setdefault(name, []).append(size)

    rewritten = []
    for playlist in sorted(os.listdir(MAC_PLAYLISTS)):
        if not playlist.endswith(".m3u8") or playlist.endswith(".bak"):
            continue
        src = os.path.join(MAC_PLAYLISTS, playlist)
        out = os.path.join(TMP, playlist)
        hits = miss = 0
        with open(src, encoding="utf-8", errors="replace") as fh, open(out, "w", encoding="utf-8") as oh:
            for line in fh:
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    oh.write(line)
                    continue
                name = stripped.rsplit("/", 1)[-1]
                candidates = set()
                for size in mac_name_to_sizes.get(name, []):
                    for stored_path in phone_size_to_paths.get(size, []):
                        candidates.add(stored_path)
                if len(candidates) == 1:
                    # The stored path is Documents-relative (LibraryPathStore),
                    # exactly what the scanner registered — a path match.
                    oh.write(f"{next(iter(candidates))}\n")
                    hits += 1
                else:
                    oh.write(line)
                    miss += 1
        rewritten.append((playlist, hits, miss))
        print(f"  {playlist}: {hits} rewritten, {miss} left as-is")

    print("→ pushing rewritten playlists")
    for playlist, _, _ in rewritten:
        sh("xcrun", "devicectl", "device", "copy", "to",
           "--device", device,
           "--domain-type", "appDataContainer",
           "--domain-identifier", "org.Petrichor.ios",
           "--source", f"{TMP}/{playlist}",
           "--destination", f"Documents/Petrichor-Playlists/{playlist}")

    print("Done. Reopen the app (or return from background) to re-import.")

if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as e:
        print(e.stderr or e.stdout, file=sys.stderr)
        sys.exit(1)
