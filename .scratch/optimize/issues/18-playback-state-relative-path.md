# 18 — `PlaybackState`: относительный путь вместо абсолютного

**Status:** ready-for-agent
**Blocked by:** —

`Models/Core/PlaybackState.swift:55,60` (`currentTrackPath = currentTrack?.url.path`,
`queueTrackPaths = queue.map { $0.url.path }`) и `AppCoordinator.swift:134`
(`sourceIdentifier = folder.url.path`) пишут в UserDefaults абсолютный путь с UUID
контейнера. Правило относительного пути формально не нарушено (это не БД), но
антипаттерн тот же: после переустановки path-fallback в
`performStateRestoration` (`AppCoordinator.swift:281-300`) никогда не сматчится,
и восстановление молча полагается на 50%-ratio проверку.

## Направление

Персистить относительный путь через `LibraryPathStore.storedPath(for:)` и здесь.
