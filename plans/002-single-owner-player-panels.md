# 002 — Give queue and lyrics panels one motion owner

- **Status**: DONE
- **Commit**: 907076d
- **Severity**: HIGH
- **Category**: Interruptibility and physicality
- **Estimated scope**: 4 files, about 140 lines changed

## Problem

`iOS/Player/NowPlayingScreen.swift:56-81` separately inserts a dismiss layer, a queue, or lyrics and applies both `.move(edge: .bottom)` and `.opacity`, followed by two root animation modifiers:

```swift
.transition(.move(edge: .bottom).combined(with: .opacity))
.animation(.spring(response: 0.38, dampingFraction: 0.86), value: showingQueue)
.animation(.spring(response: 0.38, dampingFraction: 0.86), value: showingLyrics)
```

`iOS/Components/NowPlayingPanel.swift:18-35` owns a second `dragOffset`. On a successful swipe it invokes the parent's dismissal and immediately resets its own offset to zero. The conditional transition and local gesture therefore drive the same geometry in competing transactions, which produces the duplicated/restarting animation reported during downward drag.

## Target

- One parent state machine owns panel kind, mount, visibility, and drag progress.
- Normal motion: panel enters from its measured height with `.spring(response: 0.28, dampingFraction: 0.90)`, without opacity; dismisses from the current drag position to full height with `.easeOut(duration: 0.20)`.
- Cancelled drag returns to zero with `.spring(response: 0.24, dampingFraction: 0.90)`.
- Reduce Motion: no vertical movement; opacity only using `.easeOut(duration: 0.20)`.
- Panel children report drag changes/end decisions but never keep or reset a competing offset.

## Repo conventions to follow

- Copy the mount/commit/animate/unmount lifecycle already used by `NowPlayingPresentationLayer` in `iOS/ContentView.swift:339-390`: animation-disabled insertion, `Task.yield()`, one explicit animation, delayed animation-disabled removal.
- Keep `NowPlayingPanel` as the shared material/header shell for both queue and lyrics.

## Steps

1. In `NowPlayingScreen`, replace `showingQueue`/`showingLyrics` with one private `PanelKind?` plus `panelMounted`, `panelVisible`, `panelDragOffset`, and a cancellable lifecycle task. Only one panel may exist at a time.
2. Mount the selected child offscreen in a transaction with animations disabled, yield once, and animate `panelVisible` to true using `.spring(response: 0.28, dampingFraction: 0.90)`.
3. Render one shared panel container at the bottom. Select the queue or lyrics content inside it, and drive its normal-motion offset solely from `panelVisible` plus `panelDragOffset`. Do not use `.transition(.move...)` or root `.animation(value:)` modifiers.
4. Move the panel drag state out of `NowPlayingPanel`. Change its API to callbacks such as `onDragChanged(CGFloat)` and `onDragEnded(translation:predicted:)`, or a binding owned by `NowPlayingScreen`. The shared shell may define the `DragGesture`, but it must not store its own offset.
5. On successful swipe or button/tap dismissal, animate from the current offset to the panel height with `.easeOut(duration: 0.20)`, then unmount without animation. On cancellation, spring the same offset back to zero.
6. Use opacity instead of offset only when `accessibilityReduceMotion` is true. The dim/dismiss layer may fade at `0.20` seconds, but it must share the same lifecycle task.
7. Cancel lifecycle tasks on screen disappearance and on a new presentation request.
8. Update `NowPlayingQueuePanel` and `NowPlayingLyricsPanel` initializers to fit the single owner; keep their business content and existing dismiss controls.

## Boundaries

- Do NOT change queue mutation, lyrics loading, or playback sampling behavior in this plan.
- Do NOT add a gesture recognizer library.
- Do NOT keep `showingQueue` and `showingLyrics` as independent booleans.
- Do NOT use `.move(...).combined(with: .opacity)` for normal motion.
- If the cited structure has drifted from commit `907076d`, stop and report instead of improvising.

## Verification

- **Mechanical**: the PetrichoriOS simulator build succeeds.
- **Feel check**: open queue, slowly drag its header down 20–70 points, release, and confirm the same panel returns without a jump. Drag past the threshold and confirm it continues from the finger instead of snapping up and starting over. Repeat with lyrics and the close button.
- Spam open/dismiss 10 times and switch between queue and lyrics; at no point may two panels be visible.
- With Reduce Motion, confirm only the panel opacity changes.
- **Done when**: frame-by-frame video shows one panel surface and one monotonic vertical position throughout each gesture.
