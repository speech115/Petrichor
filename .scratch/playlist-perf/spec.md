# Спека: отзывчивость плейлиста на 1000+ треков

Дата: 2026-08-08. Фаза «скорость и полировка» iOS-порта.
**Статус: resolved (2026-08-08)** — все восемь тикетов закрыты, замеры
до/после и пост-мортем — в Comments тикетов 01 и 08. Ключевой вывод
замеров: узкое место было не в SQL, а в декодировании строк `Track(row:)`
и пересборке строк из-за случайной identity; JOIN дал ~4%.

## Замеры до/после (свод)

| Фаза | До | После |
|---|---|---|
| Unit: `loadTracksForPlaylist` (медиана) | 36.1 ms | 34.5 ms |
| Unit: thumbnails | 2.3 ms | 2.0 ms |
| Sim: `loadData` холодное открытие | 113.7 ms | 99.9 ms (разброс 99–188) |
| Sim: `publishTracks` | 0.086 ms | 0.05 ms |
| Sim: тёплое повторное открытие | — | 0.7 ms |
| Device: `loadData` (2758 mp3, большой плейлист) | — | 371–527 ms |
| Device: `publishTracks` | — | 0.01–0.03 ms |

Детали и пост-мортем — Comments тикетов 01 и 08.

## Симптом

Открытие и скролл плейлиста с 1000+ треками на iPhone 16 Pro Max (2758 mp3,
13 обычных + 3 смарт-плейлиста) заметно лагает. Цель — открытие и скролл
без ощутимых задержек и хитчей, «как будто приложение сделала Apple».

## Диагноз (разведка кода, замеров ещё нет)

Семь независимых проблем на пути «тап по плейлисту → отрисованный список».
Ранжированы по ожидаемому вкладу:

1. **Публикация `@Published` с фонового потока.**
   `loadPlaylistTracks` (`Managers/Playlist/PlaylistManager.swift:135-149`) —
   синхронный, без `@MainActor`, мутирует `playlists[index].tracks`. Вызывается
   из `Task.detached` (`iOS/Library/TrackListScreen.swift:118-121` ←
   `iOS/Playlists/PlaylistDetailScreen.swift:36`), то есть публикация идёт не с
   главного потока. Смарт-путь делает это правильно через `MainActor.run`
   (`Managers/Playlist/PMSmartPlaylists.swift:155-162`).

2. **Нестабильная identity `Track`.** `let id = UUID()`
   (`Models/Core/Track.swift:6`) генерируется заново при каждом чтении из БД;
   `==`/`hash` — только по `id` (`Track.swift:204-212`). Следствия:
   - каждый reload → все id новые → `List`/`ForEach`
     (`TrackListScreen.swift:97-101`) перестраивает все 1000 строк вместо диффа;
   - `.onChange(of: libraryManager.tracks)` (`TrackListScreen.swift:67-69`)
     срабатывает всегда, даже на идентичном контенте → каскад повторных
     загрузок сразу после открытия;
   - кэш цветов `ImageUtils.cachedDominantColors(id:)`
     (`Utilities/ImageUtils.swift:316-347`) ключуется по UUID и никогда не
     переживает перезагрузку списка.

3. **`UIImage(data:)` в `body` каждой строки без кэша**
   (`iOS/Components/ArtworkTile.swift:20`) — синхронный декод на главном
   потоке при каждом проходе строки через экран.

4. **Заголовок плейлиста: `tracks.compactMap { $0.displayArtwork }` по всем
   трекам ради 4 обложек мозаики** — на каждый пересчёт `body`
   (`iOS/Playlists/PlaylistDetailScreen.swift:139-150`,
   `iOS/Components/ArtworkMosaic.swift` берёт `.prefix(4)`).

5. **`WHERE trackId IN (1000+ параметров)`** в `loadTracksForPlaylist`
   (`Managers/Database/DMPlaylists.swift:305-354`): два запроса + словарь +
   ручное восстановление порядка вместо одного JOIN по `playlist_tracks`.

6. **Hot-рефреш смарт-плейлиста тянет полноразмерные BLOB-обложки**:
   `updateSmartPlaylists` (`Managers/Playlist/PMSmartPlaylists.swift:204`)
   вызывает `getTracksForSmartPlaylist(playlist)` без `populateArtwork: false`,
   в отличие от начальной загрузки (там же, :137-140).

7. **Мутация одного плейлиста публикует весь `@Published var playlists`** —
   перерисовываются и Home-грид, и детальный экран.

## Принцип работы

Дисциплина perf-фикса: **сначала базовый замер, потом фиксы, после каждого —
повторный замер**. Тикет 01 строит петлю; остальные заблокированы им.
Каждый тикет оставляет работающий продукт (сборка + тесты зелёные).

## Тикеты

| № | Тикет | Blocked by |
|---|---|---|
| 01 | Петля замера: unit-харнес + сеяние симулятора + signposts | — |
| 02 | Потоковая корректность `loadPlaylistTracks` | 01 |
| 03 | JOIN вместо `IN (1000+)` в `loadTracksForPlaylist` | 01 |
| 04 | Заголовок-мозаика без O(n) в `body` | 01 |
| 05 | Thumbnails при hot-рефреше смарт-плейлистов | — |
| 06 | Стабильная identity `Track` | 01, 02, 03 |
| 07 | Кэш декодированных обложек в строках | 01 |
| 08 | Верификация на устройстве, до/после, уборка инструментации | 02–07 |

## Вне рамок (осознанно)

- Гранулярность `@Published playlists` (пункт 7 диагноза) — не делаем сейчас:
  после фиксов 02 и 06 лишние перерисовки должны подешеветь на порядок;
  вернёмся, только если замер 08 покажет, что это всё ещё узкое место.
- Мёртвый `Managers/Playlist/PMSmartPlaylistEvaluator.swift` — уборка
  отдельной задачей, к производительности не относится.
- Никаких слоёв обратной совместимости: устаревшие пути удаляются.

## Как собирать и гонять тесты

```bash
xcodebuild -scheme PetrichoriOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build
xcodebuild test -scheme PetrichoriOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```

Прогон на реальном iPhone — только через скилл `.claude/skills/petrichor-device/`
(обычный device destination на этой машине сломан, не чинить).
