# 04 — Заголовок-мозаика без O(n) в `body`

Status: resolved
Blocked by: 01

## Проблема

Заголовок плейлиста (`iOS/Playlists/PlaylistDetailScreen.swift:139-150`)
строит `ArtworkMosaic(covers: tracks.compactMap { $0.displayArtwork })` —
полный проход по всем 1000+ трекам с копированием Data-массивов, хотя
`ArtworkMosaic` использует только `.prefix(4)`
(`iOS/Components/ArtworkMosaic.swift:24`). `compactMap` не ленивый и
выполняется при каждом пересчёте `body` на главном потоке, а пересчёты
происходят при любом изменении `playbackManager`/`playlistManager`
(подписки через `@EnvironmentObject`, `PlaylistDetailScreen.swift:19-20`).

Там же: `refreshMissingFiles` (`PlaylistDetailScreen.swift:172-186`) делает
`playlist.tracks.map(\.url.path)` (строка 178) на главном потоке до ухода
в `Task.detached`.

## Что сделать

- Обложки заголовка: `Array(tracks.lazy.compactMap { $0.displayArtwork }.prefix(4))`
  — lazy-цепочка останавливается на четвёртой найденной обложке.
  `ArtworkMosaic` менять не нужно.
- `refreshMissingFiles`: перенести построение массива путей внутрь
  `Task.detached` вместе с проверкой `fileExists` (передав в задачу сами
  треки/URL-ы, а не пути).

## Критерии приёмки

- [ ] Мозаика выглядит как раньше (скриншот симулятора с большим плейлистом
      из сеяния тикета 01: 4 обложки, плейсхолдеры при их отсутствии).
- [ ] Оба таргета собираются, `xcodebuild test` зелёный.

## Comments

### Реализация (2026-08-08)

- `PlaylistDetailScreen.header`: `tracks.compactMap { $0.displayArtwork }` →
  `Array(tracks.lazy.compactMap { $0.displayArtwork }.prefix(4))` — цепочка
  останавливается на четвёртой обложке, `ArtworkMosaic` не менялся.
- `refreshMissingFiles`: построение массива путей и `fileExists` внутри
  `Task.detached` (передаётся `tracks` целиком, путь строит фоновая задача).

### Проверка

- Симулятор: `big` (1200 треков) открывается, заголовок (Play/Shuffle,
  подпись «1 200 songs») и строки рендерятся, падений нет. Обложек в сеяной
  библиотеке нет (mp3 без встроенного артворка) — мозаика показывает
  плейсхолдеры, как и до фикса; семантика выбора первых 4 обложек в
  порядке списка сохранена.
- Оба таргета собираются, `xcodebuild test` — 65 тестов зелёные.
