# Спека: отзывчивость списков вне плейлистов

Дата: 2026-08-13. **Статус: resolved.** Follow-up к `.scratch/playlist-perf/` (тикеты 01–13
закрыты): те же приёмы переносятся на Songs / Discover / Search / Artist /
Album и на очередь воспроизведения.

## Симптом

Плейлист на 1000+ треков уже открывается и скроллится гладко. Songs и
остальные списки всё ещё:

1. Пересобирают строки при каждом publish `playbackManager` /
   `playlistManager` (нет `.equatable()` на `TrackRow`).
2. Перед первым кадром тянут thumbnail каждого альбома библиотеки.
3. Refresh Discover читает полноразмерные BLOB обложек.
4. Старт воспроизведения из Songs кладёт в `@Published currentQueue` массив
   с тяжёлыми `Data`-полями.

## Принцип

Повторить уже доказанные фиксы плейлиста: lazy artwork, узкая инвалидация
строк, лёгкая очередь. Без новых абстракций и без `#if os` вне швов.

## Тикеты

| № | Тикет | Blocked by |
|---|---|---|
| 01 | `.equatable()` на всех `TrackRow` вне плейлиста | — |
| 02 | Lazy thumbnails для Songs / artist / album / filter / search | — |
| 03 | Discover refresh без full artwork BLOB | — |
| 04 | Очередь без artwork Data | 02 |

## Вне рамок

- Узкое observation на Home (отдельный проход).
- Удаление мёртвого `PMSmartPlaylistEvaluator`.
- Новые unit-тесты вне швов из `AGENTS.md`.
