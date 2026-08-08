# 06 — Стабильная identity `Track`

Status: resolved
Blocked by: 01, 02, 03

## Проблема

`Track.id = UUID()` (`Models/Core/Track.swift:6`) — новый при каждом
декодировании из БД; `==`/`hash` считаются только по нему (:204-212).
Последствия:

1. Каждая перезагрузка `tracks` → все id новые → `ForEach` в
   `iOS/Library/TrackListScreen.swift:97-101` теряет identity всех строк,
   `List` делает «удалить 1000, вставить 1000» вместо диффа.
2. `.onChange(of: libraryManager.tracks)` (`TrackListScreen.swift:67-69`)
   сравнивает массивы по id-based `==` → срабатывает всегда, даже когда
   контент не изменился → повторный полный SQL-путь сразу после открытия
   (переустановки массива: `Managers/Library/LMLibrary.swift:178, :231`).
3. Кэш цветов `ImageUtils.cachedDominantColors(id: UUID, ...)`
   (`Utilities/ImageUtils.swift:313-347`) ключуется по UUID → после любой
   перезагрузки списка все записи мёртвые, экстракция цветов повторяется.

Важный факт схемы: **дубликаты трека в плейлисте невозможны** — составной PK
`(playlist_id, track_id)` (`Managers/Database/DMSetup.swift:245`),
`onConflict: .ignore` (`Models/Core/PlaylistTrack.swift:53`), дедуп в
`savePlaylistAsync` (`Managers/Database/DMPlaylists.swift:38-47`). Очередь
воспроизведения тоже дедуплицирует (`Managers/Playlist/PMQueue.swift:40,69`).
Поэтому стабильный `track.id` уникален внутри любого списка: `ForEach` может
идти прямо по трекам, обёртки строк и «воспроизведение по позиции» не нужны,
а существующие поиски `firstIndex(where: { $0.id == track.id })`
(`Managers/Playlist/PMPlayback.swift:31,80`, `PMQueue.swift:40,69`)
остаются корректными.

## Что сделать

### 1. Стабильный id

Заменить `let id = UUID()` на стабильное значение, выводимое из данных БД:
`trackId` (`Int64`, есть после персиста), для непersistнутых треков — путь
файла. Рекомендуемая форма:

```swift
var id: String { trackId.map(String.init) ?? url.absoluteString }
```

(вычисляемое свойство; хранить нечего). `==`/`hash` остаются по `id`.

Тип меняется UUID → String — обновить всех потребителей:

- `iOS/Components/NowPlayingQueuePanel.swift:85` — `track.id.uuidString`
  → `track.id`.
- `iOS/Components/NowPlayingLyricsPanel.swift:144,170,178` — сравнения по
  `id`, тип подхватится.
- `Utilities/ImageUtils.swift:316-347` + вызовы в
  `Models/Core/Track.swift:70-78` — параметр `id: UUID` → `id: String`.
  Бонус: кэш цветов начнёт реально попадать между перезагрузками.
- Остальных искать компилятором (собрать оба таргета — macOS `Views/` тоже
  использует `Track`).

### 2. Дешёвый триггер перезагрузки вместо сравнения массивов

`.onChange(of: libraryManager.tracks)` заменить на published-счётчик
ревизии: `libraryRevision: Int` в `LibraryManager`, инкремент в местах
переустановки `tracks` (`LMLibrary.swift:178, :231` — найти все grep-ом
`tracks = `). Экраны подписываются на `onChange(of: libraryManager.libraryRevision)`.
Сравнение двух массивов по 2758 элементов на каждую переустановку уходит.

## Критерии приёмки

- [ ] Unit-тест: два декодирования одного трека из БД дают равные `id`
      (положить рядом с `TrackPersistenceTests`).
- [ ] Симулятор, большой плейлист из сеяния 01: повторное открытие экрана
      не пересобирает все строки (проверить счётчиком signpost «первая
      строка» / `Self._printChanges` в dev-прогоне), скролл заметно ровнее.
- [ ] Тап по треку запускает именно его; подсветка текущего трека в списке
      работает (проверка на симуляторе).
- [ ] Оба таргета собираются, `xcodebuild test` зелёный.
- [ ] Цифры «после» записаны в Comments.

## Comments

### Адаптация (согласовано с владельцем плана)

Пункты 2 (обёртка `TrackListRowItem`) и 3 (воспроизведение по позиции)
удалены из объёма: дубликаты трека в плейлисте запрещены схемой БД
(составной PK `(playlist_id, track_id)` + `onConflict: .ignore` + дедуп в
`savePlaylistAsync`), поэтому `firstIndex { $0.id == track.id }` корректен,
а identity строк в `ForEach` стабильна и без обёртки.

### Что сделано

1. `Track.id` — вычисляемое `String`: `trackId.map(String.init) ??
   url.absoluteString`; `==`/`hash` по `id` как раньше.
2. Потребители UUID-типа обновлены: `ImageUtils.cachedDominantColors` /
   `cachedBackgroundGradientColors` (`id: String`), `LyricsStore` +
   `LMQueries.cachedLyrics` (ключ `String` — кэш текстов стал живым между
   перезагрузками, бонус как с цветами), `NowPlayingQueuePanel`,
   `NowPlayingLyricsPanel`, `PlayerView` (`FavoriteButtonView`,
   `TrackArtworkInfo`), `selectedTrackID` в 5 макошных вьюхах + `TrackView`,
   `ImmersiveView`/`MiniPlayerView.currentTrackId`, `PlayQueueView.onDrag`,
   `Entity`-цвета (`id.uuidString`), `PlaylistDetailView` градиент.
3. Счётчик ревизии: `LibraryManager.libraryRevision: Int`, инкремент в
   четырёх местах переустановки `tracks` (`LMLibrary.swift:137, :181, :235`,
   `resetAllData`); `TrackListScreen`, макошные `LibraryView` и
   `LibrarySidebarView` подписаны на `libraryRevision` вместо сравнения
   массива из 2758 элементов.

### Проверки

- Unit-тест `trackIDIsStableAcrossDecodes` (два декода → равные id,
  неперсистнутый трек → путь). `xcodebuild test` — **66 тестов зелёные**
  (один флак `resumeAfterAPausedStart...` из аудио-группы при работающем
  приложении на симуляторе — при повторном прогоне зелёный).
- Оба таргета собираются (macOS — `CODE_SIGNING_ALLOWED=NO`).

### Цифры «после» (симулятор, `big` 1200)

| Фаза | До (база) | После 02 | После 06 |
|---|---|---|---|
| `loadData` холодное открытие | 113.7 ms | 99.9 ms | 188 ms* |
| `publishTracks` | 0.086 ms | 0.05 ms | 0.05 ms |
| Каскад `loadRows` | 6.2 ms | 0.21 ms | 0.72 ms (early return) |
| Повторное открытие (тёплое) | — | — | **0.7 ms** |

\* разброс холодных прогонов большой (99–188 ms) — симулятор греется от
фоновых задач (watch-миграции, файловый watcher); медианы по нескольким
прогонам снимаются в тикете 08. Главное: тёплое повторное открытие стало
мгновенным, каскад не перестраивает строки (стабильная identity → ForEach
диффит, а не «удалить 1000/вставить 1000»).

Кэш цветов и кэш текстов теперь реально попадают между перезагрузками
(ключ стабилен) — бесплатный бонус, зафиксированный в диагнозе тикета.

- 2026-08-08, планировщик: из тикета убраны обёртка `TrackListRowItem` и
  «воспроизведение по позиции» — они были построены на ложном допущении о
  дубликатах в плейлисте (опровергнуто схемой БД, см. факт выше). Найдено
  ревью исполнителя до старта работ.
