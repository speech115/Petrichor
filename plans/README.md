# Animation implementation plans

All plans were written against `ios-port` commit `907076d` after a full SwiftUI motion and performance audit.

| Plan | Title | Severity | Status |
| --- | --- | --- | --- |
| 001 | Present Now Playing as one uninterrupted surface | HIGH | DONE |
| 002 | Give queue and lyrics panels one motion owner | HIGH | DONE |
| 003 | Make continuous player motion cheap and coordinated | MEDIUM | DONE |
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
