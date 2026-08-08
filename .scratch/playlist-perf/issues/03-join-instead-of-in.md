# 03 — JOIN вместо `IN (1000+)` в `loadTracksForPlaylist`

Status: resolved
Blocked by: 01

## Проблема

`DatabaseManager.loadTracksForPlaylist`
(`Managers/Database/DMPlaylists.swift:305-354`) делает:
1) выборку `playlist_tracks` по `playlistId` с сортировкой по `position`;
2) выборку треков через `trackIds.contains(...)` → SQL `WHERE trackId IN
   (?, ?, … 1000+)`;
3) словарь `[Int64: Track]` и ручное восстановление порядка в Swift.

Для плейлиста на 1200 треков это самый тяжёлый шаг открытия: компиляция
запроса с тысячей bind-параметров, двойной проход, промежуточные аллокации.

## Что сделать

Один SQL-запрос с JOIN, сортировкой и `dateAdded` из junction-таблицы:

```sql
SELECT tracks.*, playlist_tracks.date_added AS playlist_date_added
FROM playlist_tracks
JOIN tracks ON tracks.trackId = playlist_tracks.track_id
WHERE playlist_tracks.playlist_id = ?
  AND <условие applyDuplicateFilter>
ORDER BY playlist_tracks.position
```

- Точные имена колонок взять из `PlaylistTrack.Columns` и `Track.Columns`
  (не из этого текста). GRDB-путь — `SQLRequest<Track>` c
  `Track.fetchAll(db, sql:...)` либо ассоциации GRDB; выбрать то, что короче
  и типобезопаснее, справка: mintlify `context` по GRDB.
- Условие дубликатов: посмотреть, что делает `applyDuplicateFilter`
  (grep в `Managers/Database/`), воспроизвести его в WHERE.
- `dateAdded` каждому треку сейчас присваивается вручную
  (`DMPlaylists.swift:336`); после JOIN — маппить из алиаса, либо оставить
  один лёгкий проход по строкам. (Дубликаты трека в плейлисте невозможны:
  составной PK `(playlist_id, track_id)`, `DMSetup.swift:245`.)
- Проверить план запроса: `EXPLAIN QUERY PLAN` не должен показывать full scan
  `tracks`; если нужно — индекс по `playlist_tracks(playlist_id, position)`
  добавить миграцией v8 (посмотреть существующие индексы в
  `Managers/Database/DMSetup.swift` — возможно, уже есть).
- Старый двухфазный код удалить целиком.

## Критерии приёмки

- [ ] Unit-харнес из тикета 01: порядок сохранён, время
      data-фазы записано в Comments (ожидание: заметно меньше базового).
- [ ] `M3UImportTests` и `TrackPersistenceTests` зелёные (порядок M3U —
      закреплённое спекой поведение).
- [ ] Оба таргета собираются, `xcodebuild test` зелёный.

## Comments

### Реализация (2026-08-08)

Один SQL-запрос вместо двухфазного:

```sql
SELECT tracks.*, playlist_tracks.date_added AS playlist_date_added
FROM playlist_tracks
JOIN tracks ON tracks.id = playlist_tracks.track_id
WHERE playlist_tracks.playlist_id = ?
  [AND tracks.is_duplicate = 0]   -- если hideDuplicateTracks
ORDER BY playlist_tracks.position
```

- `Track(row:)` + явный `dateAdded = row["playlist_date_added"]` (алиас
  junction-таблицы, чтобы не зависеть от порядка одноимённых колонок).
- `EXPLAIN QUERY PLAN` на сеяной БД симулятора: `SEARCH playlist_tracks
  USING INDEX idx_playlist_tracks_playlist_id` + `SEARCH tracks USING
  INTEGER PRIMARY KEY` — full scan нет. `USE TEMP B-TREE FOR ORDER BY`
  — сортировка ~1200 строк, тривиально; составной индекс
  `(playlist_id, position)` НЕ добавлял (правило «если нужно» — не нужно).
- Старый двухфазный код удалён целиком.

### Цифры unit-харнеса (медиана, 5 прогонов)

| Фаза | До (JOIN не было) | После |
|---|---|---|
| `loadTracksForPlaylist(populateArtwork: false)` | 36.1 ms | **34.5 ms** |
| `populateAlbumArtworkThumbnailsForTracks` | 2.3 ms | 2.0 ms |
| Сумма | 38.3 ms | 36.5 ms |

**Вывод замера (важно для пост-мортема):** при 1200 треках время почти не
изменилось — доминирует не SQL, а декодирование строк в `Track(row:)`
(~28 μs/строка; 1200 строк ≈ 30 ms из 34). IN(1000+) для SQLite не был
узким местом. JOIN даёт: меньше аллокаций, один проход, короче код;
реальный выигрыш проявится на device-замере (тикет 08) и при более
крупных плейлистах.

### Проверки

- `M3UImportTests`, `TrackPersistenceTests`, весь `PetrichoriOSTests` (65
  тестов) — зелёные; порядок позиций и thumbnails в харнесе подтверждены.
- Оба таргета собираются (macOS — `CODE_SIGNING_ALLOWED=NO`).
