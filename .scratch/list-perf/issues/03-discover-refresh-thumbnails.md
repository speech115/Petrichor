# 03 — Discover refresh без full artwork BLOB

Status: resolved
Blocked by: —

## Проблема

Открытие вкладки зовёт `loadDiscoverTracks(populateArtwork: false)`.
`refreshDiscoverTracks()` зовёт `loadDiscoverTracks()` с дефолтом `true` и
тянет display-size BLOB на все 50 треков.

## Что сделать

- `refreshDiscoverTracks` → `loadDiscoverTracks(populateArtwork: false)`.
- Дефолт `populateArtwork` сменить на `false`.
- При thumbnail-pass для Discover ограничить `limit: 4` (мозаика заголовка);
  остальные строки — через `ArtworkTile` loader.

## Критерии приёмки

- [ ] Refresh не читает full artwork column.
- [ ] Мозаика получает до 4 обложек.

## Comments

- 2026-08-13: Default `populateArtwork` is `false`; refresh uses the same path;
  thumbnail pass capped at `limit: 4` for the mosaic.

- 2026-08-13 thermos: restored macOS default `populateArtwork: true`; iOS
  refresh/load pass `false`. Mosaic `limit` now scans for covers (headroom),
  not hard `prefix(4)`.
