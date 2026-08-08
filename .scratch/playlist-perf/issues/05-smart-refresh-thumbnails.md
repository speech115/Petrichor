# 05 — Thumbnails при hot-рефреше смарт-плейлистов

Status: resolved
Blocked by: —

## Проблема

Начальная загрузка смарт-плейлиста корректно просит лёгкие миниатюры:
`loadSmartPlaylistTracks` → `getTracksForSmartPlaylist(playlist,
populateArtwork: false)` + `populateAlbumArtworkThumbnailsForTracks`
(`Managers/Playlist/PMSmartPlaylists.swift:137-140`).

Но hot-рефреш при изменении библиотеки — `updateSmartPlaylists()`
(`PMSmartPlaylists.swift:175-213`, вызов на строке 204) — зовёт
`getTracksForSmartPlaylist(playlist)` с дефолтным `populateArtwork: true`,
то есть читает **полноразмерный BLOB обложки для каждого трека**. Для
смарт-плейлиста на 1000+ треков это тяжёлый I/O и скачок памяти при каждом
изменении библиотеки, пока плейлист «горячий», плюс укладка большого массива
в `@Published` на главном потоке.

## Что сделать

- В `updateSmartPlaylists` привести вызов к виду начальной загрузки:
  `populateArtwork: false` + `populateAlbumArtworkThumbnailsForTracks(&tracks)`
  (зеркально строкам 137-140).
- Проверить остальные вызовы: `grep -rn "getTracksForSmartPlaylist" --include='*.swift' .`
  Каждый вызов, чьи результаты идут в списки, обязан просить thumbnails;
  полноразмерный артворк оставляют только detail/playback-контексты
  (см. комментарий в `Models/Core/Track.swift:227-232`).

## Критерии приёмки

- [ ] Все вызовы `getTracksForSmartPlaylist` перечислены в Comments с
      пометкой list/detail и итоговым значением `populateArtwork`.
- [ ] Оба таргета собираются, `xcodebuild test` зелёный.
- [ ] Смок на симуляторе: открыть смарт-плейлист, добавить файл в
      Documents/Music (симулировать изменение библиотеки), убедиться, что
      список обновился и обложки на месте.

## Comments

### Вызовы `getTracksForSmartPlaylist` (2026-08-08)

| Место | Контекст | populateArtwork | Статус |
|---|---|---|---|
| `PMSmartPlaylists.swift:103` | persistSmartPlaylist, замороженный снапшот (результат → только trackId в `saveSmartPlaylistSnapshot`) | true → **false** | исправлено |
| `PMSmartPlaylists.swift:137` | loadSmartPlaylistTracks, список | false + thumbnails | было верно |
| `PMSmartPlaylists.swift:204` | updateSmartPlaylists hot-рефреш, список | true → **false** + thumbnails | исправлено (дефект из тикета) |
| `DMPlaylists.swift:366` | getPlaylistPreviewTracks, превью Home | false | было верно |

### Смок на симуляторе

- Пометил 12 треков избранными (прямо в БД контейнера) → «Favorites, 12 songs».
- Открыл Favorites → 12 строк с плейсхолдерами обложек (сеяные mp3 без
  встроенного артворка — music.note ожидаемо).
- Изменение библиотеки при открытом смарт-плейлисте (скопировал файл в
  Documents/Music, home → иконка приложения, без рестарта процесса):
  лог `updateSmartPlaylists: Refreshing smart playlists after library change
  (2 cold, 1 hot)` — Favorites в hot-пути, рефреш через thumbnails.
- Список после рефреша корректный (те же 12 строк), без падений.

### Сборка

- `PetrichoriOS` собирается, `xcodebuild test` — 65 тестов зелёные.
- `Petrichor` (macOS): компилируется (проверено с `CODE_SIGNING_ALLOWED=NO`;
  на машине нет Developer ID-сертификата — подпись падает и без моих правок).
