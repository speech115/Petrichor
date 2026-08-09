# Animation implementation plans

All plans were written against `ios-port` baseline `907076d` after a full
SwiftUI motion and performance audit, then executed in `1fca87e`. These are
execution/audit artifacts, not tracker tickets; authoritative task status and
publication history live in `.scratch/playlist-perf/issues/13-now-playing-unified-transition.md`.

| Plan | Title | Severity | Status |
| --- | --- | --- | --- |
| 001 | Present Now Playing as one uninterrupted surface | HIGH | IMPLEMENTED |
| 002 | Give queue and lyrics panels one motion owner | HIGH | IMPLEMENTED |
| 003 | Make continuous player motion cheap and coordinated | MEDIUM | IMPLEMENTED |
| 004 | Narrow SwiftUI invalidation around playback and large lists | HIGH | PARTIAL |

## Execution order

1. `001-single-surface-player-presentation.md`
2. `002-single-owner-player-panels.md`
3. `003-polish-continuous-player-motion.md`
4. `004-narrow-player-invalidations.md`

Plan 003 depends on the mounted/covered-content lifecycle from plan 001. Plan 004 must be last because it changes observation ownership across views modified by the first three plans. Run the simulator build after every plan; run the complete PetrichoriOS test suite and the video feel-check after plan 004.

Plan 004 is partial only for the off-main generic sectioner step; its player
observation work is complete. The plan documents why the low-cost sectioner was
kept on the main actor instead of widening Swift 6 sendability changes.

## Verification actually completed

- Simulator build and the complete 66-test suite passed after implementation.
- Full-player and panel motion were checked frame-by-frame; the ETTrace evidence
  is stored under `.scratch/playlist-perf/artifacts/ettrace-2026-08-09-player-transition/`.
- The later light-theme follow-up passed three open/drag-dismiss cycles on the
  1,505-track simulator fixture.
- Still pending: a dedicated Reduce Motion pass, ten repeated queue/lyrics panel
  cycles, the one-minute synced-lyrics check, and final visual acceptance of the
  latest build by the user on the physical iPhone.
