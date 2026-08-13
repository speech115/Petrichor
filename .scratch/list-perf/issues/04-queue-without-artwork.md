# 04 — Очередь без artwork Data

Status: resolved
Blocked by: 02

## Проблема

`beginPlayback` кладёт `contextTracks` в `@Published currentQueue`. После
тикета 02 context может остаться лёгким, но любой путь с thumbnail/full art
всё ещё копирует `Data` в очередь. Playback и Now Playing уже догружают
обложку отдельно.

## Что сделать

- Хелпер `Track.withoutArtwork()` рядом с `withFavoriteStatus`.
- В `beginPlayback` и `createLibraryQueue` / одиночных вставках очереди
  очищать artwork-поля перед publish.
- `playNext` / `addToQueue` тоже кладут очищенную копию.

## Критерии приёмки

- [ ] `currentQueue` не несёт `albumArtworkData` / `albumArtworkThumbnail`.
- [ ] Now Playing по-прежнему получает artwork через существующий enrichment.

## Comments

- 2026-08-13: `Track.withoutArtwork()` used in beginPlayback, createLibraryQueue,
  playNext, addToQueue, and AppCoordinator queue restore.

- 2026-08-13 thermos: `replaceCurrentQueue` / `replaceCurrentQueueEntry` /
  insert/append helpers are the sole queue writers; PMTrackUpdate, shuffle,
  restore, and PlayQueue preview go through them. Restore no longer bulk-loads
  artwork for the whole queue.
