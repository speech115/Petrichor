# 004 — Narrow SwiftUI invalidation around playback and large lists

- **Status**: PARTIAL
- **Baseline**: 907076d
- **Implementation**: 1fca87e (player projections complete; sectioner deferred)
- **Severity**: HIGH
- **Category**: Performance
- **Estimated scope**: 6–8 files, about 180 lines changed

## Problem

`NowPlayingScreen`, `PlayerTransport`, and `NowPlayingQueuePanel` observe entire managers even though they render different slices. `PlaylistManager` publishes playlist catalog edits, modal presentation, queue contents, queue index, shuffle, repeat, and source from one object. A queue mutation can therefore redraw the entire full player and a playback-state publication can redraw a large queue.

`iOS/Library/TrackListScreen.swift:123-136` loads rows off-main but groups them into sections on the main actor:

```swift
let loaded = await Task.detached(priority: .userInitiated) {
    await load()
}.value
...
tracks = loaded
sections = sectioner(loaded)
```

For 600–1500 rows, startup work competes with taps and the tab accessory animation.

## Target

- Preserve manager command methods but expose narrow `ObservableObject` projections, following the existing `PlaybackAvailabilityObservation`, `PlaylistCatalogObservation`, and `PlaylistCreatePresentationObservation` pattern.
- Player surface observes only current track and playing state.
- Transport observes only current track availability, playing state, shuffle, and repeat.
- Queue observes only queue contents/index and the playing indicator.
- Playlist/catalog/modal publications must not invalidate Now Playing or transport.
- Build track sections in the same detached task as row loading, then publish `tracks` and `sections` together in one main-actor turn.

## Repo conventions to follow

- Add projections beside their managers in `Managers/PlaybackManager.swift` and `Managers/Playlist/PlaylistManager.swift`, using Combine subscriptions stored in `AnyCancellable`/`Set<AnyCancellable>` exactly like existing observation classes.
- Expose each projection as a `lazy var` on its manager. Do not add a new global store or dependency-injection framework.
- Keep command calls on the original manager reference; projections are read-only presentation state.

## Steps

1. Add `PlaybackPresentationObservation` with published `currentTrack` and `isPlaying`, applying `removeDuplicates` where Equatable identity/state permits. Add one lazy instance to `PlaybackManager`.
2. Add `PlaylistTransportObservation` with published `isShuffleEnabled` and `repeatMode`, and `PlaylistQueueObservation` with `currentQueue` plus `currentQueueIndex`. Add lazy instances to `PlaylistManager`.
3. Refactor Now Playing-related views so broad manager objects used only for commands are plain stored references, while the new projections are `@ObservedObject`. Initialize them explicitly from the managers at the owning view boundary; do not try to read an environment object in `init`.
4. Pass the manager references/projections down through initializers from `ContentView` or a small owner view. Remove redundant `@EnvironmentObject` observation from children that would reintroduce broad invalidation.
5. Keep `PlaybackProgressState` separately observed only by scrubber/time and lyrics; it must not invalidate artwork, the queue list, or the whole `NowPlayingScreen` on each time tick.
6. In `TrackListScreen.loadRows()`, compute `(loaded, sectioner(loaded))` off-main, check cancellation, then assign `tracks` and `sections` in one turn. Preserve `isLoading` and `onRowsChange` semantics.
7. If Swift 6 sendability prevents moving the generic `sectioner` closure into a detached task, make the smallest safe change: declare the loader/sectioner closures `@Sendable` and adjust call sites only where compilation requires. Do not hide warnings with `@unchecked Sendable`.
8. Confirm duplicate queue rows have unique display identity as required by plan 003; do not change persistent `Track.id`.

## Boundaries

- Do NOT change manager business logic or the four platform seams.
- Do NOT add backward-compatible wrappers, global state, or third-party observation libraries.
- Do NOT publish playback progress from the new whole-player projection.
- Do NOT add SwiftUI view tests; repository policy uses simulator/device verification for views.
- If the cited structure has drifted from commit `907076d`, stop and report instead of improvising.

## Execution deviation

The player/transport/queue observation projections and duplicate queue-row
identity are implemented. Step 6 remains intentionally unimplemented:
`TrackListScreen`'s current sectioner is constant-time for the 600–1505-row
lists used here, while moving its generic closure into `Task.detached` crosses a
Swift 6 actor/`@Sendable` boundary and would require a broader concurrency
refactor. No `@unchecked Sendable` or warning suppression was introduced for a
non-hot path.

## Verification

- **Mechanical**: `xcodebuild -scheme PetrichoriOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build` succeeds and the existing PetrichoriOS test command passes.
- Add temporary `_printChanges()` only if needed for diagnosis, then remove it. While a 1,000+ track queue is visible, progress ticks must not re-evaluate every queue row; changing playlist catalog/modal state must not re-evaluate the player surface.
- **Feel check**: cold-open the 1,505-track simulator fixture, immediately scroll and tap a song. The list must remain responsive while rows appear; minimizing the tab bar and opening Now Playing must not show multi-frame stalls attributable to manager fan-out.
- **Done when**: source contains narrow projections, large section construction is off-main, build/tests pass, and simulator traces show no broad per-tick player/queue invalidation.
