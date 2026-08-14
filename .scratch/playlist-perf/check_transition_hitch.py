#!/usr/bin/env python3
"""Detect mid-transition hitch from a simulator recording.

Looks for large frame-to-frame mean-squared error spikes after the first
content change (open) — a proxy for "feels laggy" when chrome/palette/list
pops in during a zoom. Not a substitute for Instruments; a cheap gate.
"""

from __future__ import annotations

import subprocess
import sys

import numpy as np

WIDTH = 220
HEIGHT = 478
FRAME_BYTES = WIDTH * HEIGHT * 3


def read_frames(path: str) -> list[np.ndarray]:
    process = subprocess.Popen(
        [
            "ffmpeg",
            "-loglevel",
            "error",
            "-i",
            path,
            "-vf",
            f"scale={WIDTH}:{HEIGHT}",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "rgb24",
            "-",
        ],
        stdout=subprocess.PIPE,
    )
    assert process.stdout is not None
    frames: list[np.ndarray] = []
    while True:
        payload = process.stdout.read(FRAME_BYTES)
        if len(payload) != FRAME_BYTES:
            break
        frames.append(
            np.frombuffer(payload, dtype=np.uint8)
            .reshape(HEIGHT, WIDTH, 3)
            .astype(np.float32)
        )
    if process.wait() != 0 or not frames:
        raise SystemExit("FAIL: video could not be decoded")
    return frames


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} VIDEO")

    frames = read_frames(sys.argv[1])
    if len(frames) < 8:
        raise SystemExit("FAIL: need at least ~0.25s of video")

    diffs = [
        float(np.mean((frames[i] - frames[i - 1]) ** 2))
        for i in range(1, len(frames))
    ]
    # Ignore the single largest jump (the open itself) and look at the next
    # spikes — those are mid-transition content changes.
    ordered = sorted(diffs, reverse=True)
    open_jump = ordered[0]
    secondary = ordered[1] if len(ordered) > 1 else 0.0
    tertiary = ordered[2] if len(ordered) > 2 else 0.0
    median = float(np.median(diffs))

    print(f"frames={len(frames)}")
    print(f"open_mse={open_jump:.1f}")
    print(f"secondary_mse={secondary:.1f}")
    print(f"tertiary_mse={tertiary:.1f}")
    print(f"median_mse={median:.1f}")

    # Secondary spike near the open jump means chrome changed mid-flight.
    if open_jump > 50 and secondary > open_jump * 0.35 and secondary > 80:
        print(
            f"FAIL: mid-transition hitch (secondary {secondary:.1f} vs open {open_jump:.1f})"
        )
        raise SystemExit(1)

    print("PASS: no large secondary content spike after open")


if __name__ == "__main__":
    main()
