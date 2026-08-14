# Zoom transition hitch (2026-08-13)

## Symptom

Zoom playlist/album and mini→NP «есть, но подлагивает» vs Music.

## Loop

```bash
xcrun simctl io <udid> recordVideo --codec=h264 --force /tmp/petrichor-zoom.mp4
# Favorites open + mini→NP
pkill -INT -f 'simctl io .* recordVideo'
python3 .scratch/playlist-perf/check_transition_hitch.py /tmp/petrichor-zoom.mp4
```

Secondary frame-MSE spike after the open jump = mid-transition chrome change.

## Before → after

| | secondary_mse | gate |
|---|---|---|
| before | 19646 | FAIL |
| after | 3194 | PASS |

## Fixes

1. Defer `nowPlayingMounted` ~380ms (don't thrash TabView under zoom source)
2. Sync NP palette from color cache on first frame; defer fine scrubber sampling
3. Artwork decode completes without 180ms opacity tween
4. Track list publish without animation
5. Detail wash tint: sync cache hit immediately; async miss after ~320ms, no animation
