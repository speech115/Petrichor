#!/usr/bin/env python3
"""Check a light-theme mini -> full -> dismiss simulator recording.

Requires ffmpeg on PATH and numpy. The thresholds are intentionally specific to
the iPhone 17 Pro Max simulator capture used for issue 13; this is a repeatable
diagnostic gate, not a general image-quality metric.
"""

import subprocess
import sys

import numpy as np


WIDTH = 220
HEIGHT = 478
FRAME_BYTES = WIDTH * HEIGHT * 3
MAX_LUMA_JUMP = 160
MAX_ARTWORK_SCALE_SPREAD = 0.12


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
            .copy()
        )
    if process.wait() != 0 or not frames:
        raise SystemExit("FAIL: video could not be decoded")
    return frames


def artwork_heights(frames: list[np.ndarray]) -> list[int]:
    heights: list[int] = []
    for frame in frames:
        gray = frame.mean(axis=2)
        if gray.mean() > 90:
            continue
        side = (gray[:, :10].mean(axis=1) + gray[:, -10:].mean(axis=1)) / 2
        center = gray[:, 30:-30].mean(axis=1)
        rows = np.where(center - side > 10)[0]
        runs: list[list[int]] = []
        for row in rows:
            if not runs or row > runs[-1][-1] + 1:
                runs.append([int(row)])
            else:
                runs[-1].append(int(row))
        candidates = [run for run in runs if 120 <= len(run) <= 230]
        if candidates:
            heights.append(max(map(len, candidates)))
    return heights


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} VIDEO")

    frames = read_frames(sys.argv[1])
    if len(frames) < 2:
        raise SystemExit("FAIL: video has fewer than two decoded frames")
    means = np.array([frame.mean() for frame in frames])
    max_luma_jump = float(np.abs(np.diff(means)).max())

    stable_heights = [height for height in artwork_heights(frames) if height >= 150]
    scale_spread = 0.0
    if stable_heights:
        scale_spread = (
            (max(stable_heights) - min(stable_heights)) / max(stable_heights)
        )

    failures: list[str] = []
    if max_luma_jump > MAX_LUMA_JUMP:
        failures.append(
            f"theme changes in one decoded frame (luma delta {max_luma_jump:.1f})"
        )
    if scale_spread > MAX_ARTWORK_SCALE_SPREAD:
        failures.append(
            f"player artwork changes scale during the transition ({scale_spread:.1%})"
        )

    print(f"frames={len(frames)}")
    print(f"max_luma_jump={max_luma_jump:.1f}")
    print(f"artwork_scale_spread={scale_spread:.1%}")
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        raise SystemExit(1)
    print("PASS: theme and player geometry remain continuous")


if __name__ == "__main__":
    main()
