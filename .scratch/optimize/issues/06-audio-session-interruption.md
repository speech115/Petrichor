# 06 — Аудиосессия: main-hop + re-activate + `wasPlaying`

**Status:** ready-for-agent
**Blocked by:** —

`iOS/AudioSessionController.swift` — три дефекта в одном файле:

1. `:45-67` `handleInterruption`/`handleRouteChange` не маршалят на main, тогда как
   `onPause`/`onResume` — MainActor-замыкания, собранные в `AVQueuePlayerBackend`
   (`:88-91`). Уведомления AVAudioSession приходят не на главном потоке →
   runtime-trap в Swift 6 (сравни `RemoteCommandManager.swift:52-101`, который
   оборачивает каждый handler в `MainActor.assumeIsolated`).
2. `:49-56` на `.ended` сессия не переактивируется (`setActive(true)`) перед
   `onResume()` → после звонка/будильника `player.play()` даёт тишину.
3. `.began` → `onPause()` безусловно: если пользователь уже на паузе, `.ended`
   с `.shouldResume` неожиданно стартует звук.

## Направление

`Task { @MainActor in onPause() }` в обоих handler'ах; на `.shouldResume` сначала
`setActive(true)`, потом `onResume()`; на `.began` фиксировать `wasPlaying` и
возобновлять только если было true.
