# 08 — Фоновое сохранение: encode+flush с main

**Status:** ready-for-agent
**Blocked by:** —

`iOS/PetrichorApp.swift:95-97` → `Application/AppCoordinator.swift:116-169`
`savePlaybackState()` выполняется синхронно на `@MainActor` в коротком окне
background-transition. `PlaybackState` кодирует весь `currentQueue` (до 2829
треков), а `playbackJournal?.flush()` делает синхронный `FileHandle` seek+write.
На большой библиотеке это encode+I/O на главном потоке; система может
приостановить процесс на середине записи — потеряется batch журнала или state.

## Направление

`beginBackgroundTask` и/или вынос encode+flush с main-актора; как минимум
флашить журнал до encode.
