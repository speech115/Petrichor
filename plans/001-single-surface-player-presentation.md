# 001 — Present Now Playing as one uninterrupted surface

- **Status**: DONE
- **Commit**: 907076d
- **Severity**: HIGH
- **Category**: Interruptibility, performance, accessibility
- **Estimated scope**: 2 files, about 100 lines changed

## Problem

`iOS/ContentView.swift:308-322` drives the full-screen surface with both a vertical transform and opacity on every normal presentation:

```swift
NowPlayingScreen(
    isPresented: $isPresented,
    presentationDragOffset: $dragOffset
)
.compositingGroup()
.offset(y: verticalOffset(in: geometry))
.opacity(isVisible ? 1 : 0)
```

That crossfade exposes the still-live mini player underneath and makes the artwork appear to commit separately from the moving player. The underlying `TabView` also remains active and accessible while the player covers it.

`iOS/ContentView.swift:403-475` replaces the entire mini-player subtree when `tabViewBottomAccessoryPlacement` changes. Scrolling the playlist therefore rebuilds artwork, labels, and controls exactly while the system tab accessory is resizing.

## Target

- Normal motion: mount the full player offscreen without animation, wait one main-actor yield, then move the single composited surface using `.spring(response: 0.30, dampingFraction: 0.94)`. Do not change opacity.
- Normal dismissal: continue from the current positive drag offset to the viewport height with `.easeOut(duration: 0.22)`, then unmount without animation.
- Reduce Motion: keep the surface at offset zero and use opacity only with `.easeOut(duration: 0.20)`.
- While mounted, disable hit testing and accessibility for the `TabView`; do the same for the mini-player accessory so it cannot show through or animate beneath the overlay.
- Keep one stable mini-player hierarchy. Treat `.expanded` and `nil` as expanded. Vary artwork size, text fonts, padding, and progress opacity/frame inside that hierarchy; do not branch into `compactRow` and `expandedRow` root trees.

## Repo conventions to follow

- Preserve the in-hierarchy overlay in `iOS/ContentView.swift:116-122`; do not return to `.sheet` or `.fullScreenCover`.
- Preserve the existing mount-before-animation transaction and `Task.yield()` lifecycle in `NowPlayingPresentationLayer.present()`.
- Keep the one `.compositingGroup()` around the whole player because it prevents the decoded artwork layer from committing a frame before the rest of the screen.

## Steps

1. In `ContentView.body`, wrap the `TabView` and its accessory in a private `mainInterface` view or apply `.allowsHitTesting(!showingNowPlaying)` and `.accessibilityHidden(showingNowPlaying)` to the tab hierarchy before the overlay.
2. Pass the mounted state from `NowPlayingPresentationLayer` outward through a binding/callback, or derive the hiding from `showingNowPlaying`, so the underlying hierarchy is disabled for the full mount-to-unmount lifecycle. Do not add a global singleton.
3. In `NowPlayingPresentationLayer`, separate normal-motion rendering from Reduce Motion rendering: normal motion changes only `offset`; Reduce Motion changes only `opacity`.
4. Change the entrance spring to `.spring(response: 0.30, dampingFraction: 0.94)` and normal exit to `.easeOut(duration: 0.22)`. Keep cancellable lifecycle tasks and animation-disabled unmounting.
5. Add `.accessibilityAddTraits(.isModal)` to the visible Now Playing surface if supported by the current SDK.
6. Replace `if placement == .expanded { expandedRow } else { compactRow }` with one `VStack`/`HStack`. Use `let isCompact = placement == .compact`; make artwork `44` or `56`, title font `.subheadline.weight(.semibold)` or `.headline`, subtitle `.caption` or `.subheadline`, vertical padding `8` or `10`, and show the progress line with opacity/height without replacing the row identity.
7. Do not add an explicit animation to placement changes; let the system accessory transition drive layout.

## Boundaries

- Do NOT change tab destinations, navigation, playback behavior, or player layout.
- Do NOT remove `.compositingGroup()` without frame-by-frame evidence that artwork and controls still enter together.
- Do NOT add dependencies or a second presentation mechanism.
- If the cited structure has drifted from commit `907076d`, stop and report instead of improvising.

## Verification

- **Mechanical**: `xcodebuild -scheme PetrichoriOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build` succeeds.
- **Feel check**: record the iPhone 17 Pro Max simulator at 60 fps. Open and dismiss Now Playing at normal speed and frame-by-frame. Confirm the artwork, background, title, and controls enter on the same first moving frame; no mini-player sliver appears below; dragging down never creates a second copy; the dismissal continues from the finger.
- Scroll a long playlist until the tab bar minimizes. Confirm the mini-player contents retain identity and no artwork/title flash occurs.
- Toggle Reduce Motion and confirm the player crossfades without vertical movement and remains usable.
- **Done when**: all visual checks pass twice from a cold launch and twice while audio is playing.
