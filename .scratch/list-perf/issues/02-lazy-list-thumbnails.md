# 02 — Lazy thumbnails для Songs / artist / album / filter / search

Status: resolved
Blocked by: —

## Проблема

Плейлист грузит максимум 4 миниатюры для мозаики; `LMQueries.getAllTracks`
и соседние обёртки заполняют thumbnail каждого альбома до первого кадра.
`ArtworkTile` + `TrackRow` loader уже умеют подгружать видимые строки.

## Что сделать

- В `Managers/Library/LMQueries.swift` убрать bulk
  `populateAlbumArtworkThumbnailsForTracks` из list wrappers
  (`getAllTracks`, `getTracksBy`, `getTracksForArtist`, `getTracksForAlbum`,
  `getTracksInFolder`, `search`).
- Обновить комментарии в `LMQueries` и `TrackRow`: списки больше не несут
  thumbnail заранее; видимая строка читает его сама.
- В `SearchView.topResultArtwork` добавить loader по `albumId` /
  track artwork, как у `TrackRow`.

## Критерии приёмки

- [ ] List wrappers не делают полный thumbnail pass.
- [ ] Строки и Top Result всё ещё показывают обложку через loader.

## Comments

- 2026-08-13: List wrappers no longer bulk-fill thumbnails. TrackRow / Search
  Top Result load via ArtworkTile. Folders (macOS) still get full artwork from
  `getTracksForFolder`. `getAlbumArtworkThumbnail` no longer falls back to the
  display-size BLOB.

- 2026-08-13 thermos: shared `ArtworkDataLoader.trackListArtwork` (thumbnail
  then album/track `getArtworkData` fallback). Stale DMQueries / displayArtwork
  comments aligned with 0 / mosaic-limit / Folders-full policy.
