# 01 — `.equatable()` на всех TrackRow вне плейлиста

Status: resolved
Blocked by: —

## Проблема

`PlaylistDetailScreen` уже ставит `.equatable()` на `TrackRow` (тикет 12
playlist-perf). Songs / Discover / Search / Artist / Album строят голый
`TrackRow` и держат `@EnvironmentObject` менеджеров — play/pause и очередь
пересобирают список.

## Что сделать

Добавить `.equatable()` на каждый `TrackRow(` в:

- `iOS/Library/TrackListView.swift`
- `iOS/Discover/DiscoverTabView.swift`
- `iOS/Search/SearchView.swift`
- `iOS/Library/ArtistPage.swift`
- `iOS/Library/AlbumPage.swift`

Менеджеры уже передаются plain `let` — менять сигнатуру не нужно.

## Критерии приёмки

- [ ] Все перечисленные сайты имеют `.equatable()`.
- [ ] `PlaylistDetailScreen` без регрессии.

## Comments

- 2026-08-13: `.equatable()` added on TrackListView, DiscoverTabView, SearchView,
  ArtistPage, AlbumPage — same pattern as PlaylistDetailScreen.
