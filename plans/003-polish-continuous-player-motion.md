# 003 — Make continuous player motion cheap and coordinated

- **Status**: DONE
- **Commit**: 907076d
- **Severity**: MEDIUM
- **Category**: Performance, easing, accessibility
- **Estimated scope**: 6 files, about 100 lines changed

## Problem

Several high-frequency effects start independent animations or relayout:

```swift
// iOS/Player/PlayerScrubber.swift:48-60
let height: CGFloat = isScrubbing ? 12 : 7
...
.frame(height: height)
.animation(.spring(response: 0.28, dampingFraction: 0.8), value: isScrubbing)
```

```swift
// iOS/Components/NowPlayingLyricsPanel.swift:103-127
VStack(spacing: 12) { ... }
.animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentLineIndex)
...
withAnimation { proxy.scrollTo(newIndex, anchor: .center) }
```

```swift
// iOS/Components/EqualizerBars.swift:26
TimelineView(.animation(paused: !(animating && !reduceMotion)))
```

The scrubber mutates layout and uses an uncancellable delayed callback; lyrics attach an animation to every row and start a second animated scroll; the equalizer runs at display cadence even when the whole tab hierarchy is covered.

## Target

- Scrubber keeps a fixed 12-point layout height and uses only `scaleEffect(y:)`: `7 / 12` idle and `1` active. Spring `.spring(response: 0.24, dampingFraction: 0.88)`; no spring with Reduce Motion.
- Replace `DispatchQueue.main.asyncAfter` with a cancellable `Task`, sleeping 120 ms, cancelled by the next gesture and on disappear.
- Lyrics use `LazyVStack`; no per-row `.animation(value:)`. One state transaction uses `.spring(response: 0.28, dampingFraction: 0.88)` and one scroll transaction uses the same curve. Reduce Motion changes immediately and scrolls without animation. Loading shimmer is static under Reduce Motion.
- Equalizer uses `TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: ...))` and also pauses whenever the full player covers the track list. Pass that coverage through a SwiftUI environment value, not a singleton.
- Pause/resume artwork uses scale `0.86` and `.spring(response: 0.28, dampingFraction: 0.86)`; no scale animation under Reduce Motion.
- Palette's first resolved value applies with animations disabled; later track palettes crossfade with `.easeInOut(duration: 0.25)`.

## Repo conventions to follow

- Continue using wall-clock phase in `EqualizerBars`; do not introduce per-row timers.
- Continue using `Task` cancellation patterns already present in `NowPlayingPresentationLayer` and palette loading.
- Keep haptics only at the start of a scrub and on existing buttons.

## Steps

1. Refactor `PlayerScrubber.track` to fixed geometry and a vertical transform. Add `@Environment(\.accessibilityReduceMotion)` and `@State private var releaseTask`. Cancel it on a new drag and `.onDisappear`.
2. Change `NowPlayingLyricsPanel` to `LazyVStack`, remove the per-row animation modifier, use the exact spring once per active-line change, and make scrolling nonanimated under Reduce Motion. Gate `phaseAnimator` with Reduce Motion or replace it with a static `0.5` opacity placeholder in that mode.
3. Add a private/public project-local environment key such as `playerSurfaceCoversContent` in the iOS UI layer. Set it on the underlying tab hierarchy while Now Playing is mounted. Read it in `EqualizerBars` and include `!playerSurfaceCoversContent` in the timeline's pause expression.
4. Cap EqualizerBars at 30 updates per second with `minimumInterval: 1.0 / 30.0`.
5. In `NowPlayingScreen`, change artwork pause scale/spring to the target values.
6. Track whether a real palette has been applied for the mounted screen. Apply the first resolved palette in an animation-disabled transaction; wrap only subsequent palette assignments in `.easeInOut(duration: 0.25)`. Remove the unconditional `.animation(duration: 0.45, value: palette)` from the gradient.
7. Add `.contentTransition(.symbolEffect(.replace))` or the existing `.replace.offUp` pattern to favorite/repeat glyph changes. Animate toggle chip opacity with `.easeOut(duration: 0.16)` unless Reduce Motion is enabled. Do not animate unrelated layout.
8. In queue reorder, replace `.default` with `.spring(response: 0.24, dampingFraction: 0.90)` and use unique occurrence identity for duplicate tracks rather than `id: \.element.id`.

## Boundaries

- Do NOT animate scrubber width or progress publications.
- Do NOT add one timer per row or per lyric line.
- Do NOT alter playback seek math, queue semantics, or lyric parsing.
- Do NOT increase the equalizer update frequency above 30 Hz.
- If the cited structure has drifted from commit `907076d`, stop and report instead of improvising.

## Verification

- **Mechanical**: simulator build succeeds; existing non-view tests pass.
- **Feel check**: scrub rapidly and re-grab within 120 ms; the bar never collapses under the finger and surrounding labels do not move. Pause/resume repeatedly; artwork settles in under 300 ms without bounce.
- Watch synced lyrics for one minute: only the active line and scroll move, scrolling does not double-ease, and Reduce Motion makes the change immediate.
- Open Now Playing over a playing track and verify the hidden list equalizer stops consuming timeline frames; dismiss and confirm it resumes.
- **Done when**: no stale scrub release, no duplicate lyric animation, and normal player controls remain responsive while these effects run.
