# 01 — Петля замера: unit-харнес, сеяние симулятора, signposts

Status: resolved
Blocked by: —

## Зачем

Все фиксы этой фазы (02–07) — про производительность. Без воспроизводимого
замера «до» нельзя утверждать, что стало «после». Этот тикет строит петлю
обратной связи; остальные тикеты им заблокированы.

## Что сделать

### 1. Unit-харнес времени загрузки плейлиста

Новый файл `Tests/PetrichoriOSTests/PlaylistLoadPerfTests.swift`.

- Инфраструктура уже есть: `Tests/PetrichoriOSTests/TestFixtures.swift` —
  `makeTestDatabasePool()` (строки 11-15) создаёт временную WAL-базу,
  миграции регистрирует `Managers/Database/DatabaseMigration.swift`.
- Насеять напрямую в БД (без сканирования файлов): ~100 альбомов с
  `artwork_thumbnail` ≈ 10 КБ случайных байт каждый, 1500 треков,
  один плейлист (`playlists` + `playlist_tracks`) с 1200 **уникальными**
  позициями. Дубликаты трека в плейлисте невозможны на уровне схемы:
  составной PK `(playlist_id, track_id)` (`DMSetup.swift:245`),
  `onConflict: .ignore` (`PlaylistTrack.swift:53`), дедуп в
  `savePlaylistAsync` (`DMPlaylists.swift:38-47`). Как пишутся записи — смотри
  `Tests/PetrichoriOSTests/TrackPersistenceTests.swift` и модели
  `Models/Core/Track.swift`, `Models/Core/Playlist.swift`,
  `PlaylistTrack` (в `Managers/Database/DMPlaylists.swift` или рядом).
- Замерить `ContinuousClock`-ом две фазы по отдельности и сумму:
  `loadTracksForPlaylist(id, populateArtwork: false)` и
  `populateAlbumArtworkThumbnailsForTracks(&tracks)`
  (`Managers/Database/DMQueries.swift:34-63`). 5 прогонов, печатать медиану
  через `print` с префиксом `[PERF-0808]`.
- Ассертить пока только корректность: 1200 треков, порядок позиций сохранён,
  все trackId уникальны. Порог по мс НЕ ассертить (железо разное);
  цифры фиксируются в Comments этого тикета.

### 2. Signpost-инструментация пути открытия

Временная, вся помечена тегом `[PERF-0808]` в комментарии рядом с каждой
вставкой — уборка в тикете 08 одним grep.

- Создать `Utilities/PerfSignpost.swift`: обёртка над `OSSignposter`
  (subsystem — bundle id, category `"perf"`), методы
  `begin(_ name: StaticString) -> OSSignpostIntervalState` / `end`.
  В `Core/Logger.swift` signpost-ов нет — не расширять Logger, отдельный файл.
- Обернуть интервалами:
  - `loadRows()` целиком (`iOS/Library/TrackListScreen.swift:118-127`);
  - вызов `load()` внутри `Task.detached` (это время данных);
  - присвоение `tracks`/`sections` (это время публикации);
  - `loadTracksForPlaylist` и `populateAlbumArtworkThumbnailsForTracks`.
- Плюс `os_signpost` event на первый вызов `row(...)` после загрузки —
  грубая метка «первая строка отрисована».

### 3. Реалистичные данные на симуляторе

Сценарий, повторяемый одной командой (оформить как скрипт
`.scratch/playlist-perf/seed-simulator.sh`):

- Сгенерировать 1500 mp3: взять генератор тишины с ID3-тегами из
  `Tests/PetrichoriOSTests/TestFixtures.swift` (`makeSilentMP3`, строки ~122+)
  — вынести генерацию в маленький swift-скрипт или временный тест, который
  пишет файлы в папку скратчпада (`~/…/scratch/perf-library/`). Имена файлов
  и теги: ~100 разных «альбомов» по ~15 треков.
- Сгенерировать `big.m3u` со ссылками на 1200 из них (относительные пути) —
  импорт M3U в приложении создаёт плейлист (поведение закреплено
  `Tests/PetrichoriOSTests/M3UImportTests.swift`).
- Залить: `xcrun simctl push booted org.Petrichor.ios <файлы> Documents/Music/`
  (симулятор iPhone 17 Pro Max, см. `.agents/skills/ios-simulator/SKILL.md`).
- Запустить приложение (xcodebuildmcp `build_run_sim`), дождаться скана,
  открыть плейлист big через UI-автоматизацию (`snapshot_ui` + `tap`),
  снять цифры signpost-интервалов из логов
  (`launch_app_sim` захватывает логи; фильтр по `[PERF-0808]` /
  `log stream --predicate 'subsystem == "org.Petrichor.ios"'`).

## Критерии приёмки

- [ ] `xcodebuild test` зелёный, включая новый `PlaylistLoadPerfTests`.
- [ ] В Comments тикета записана таблица базовых цифр: unit-харнес
      (loadTracksForPlaylist, populateThumbnails, сумма) и симулятор
      (loadRows целиком, data-фаза, publish-фаза, до первой строки).
- [ ] Сеяние симулятора воспроизводится скриптом, путь к нему записан
      в Comments.
- [ ] Вся инструментация находится grep-ом: `grep -rn "PERF-0808" --include='*.swift' .`

## Comments

### База «до» (2026-08-08, iPhone 17 Pro Max симулятор, Debug)

**Unit-харнес** `PlaylistLoadPerfTests.playlistLoadTimingOnSeededDatabase`
(сеяная БД: 100 альбомов × thumbnail 10 КБ, 1500 треков, плейлист 1200
уникальных позиций; 5 прогонов, медиана):

| Фаза | Медиана |
|---|---|
| `loadTracksForPlaylist(populateArtwork: false)` | **36.1 ms** (36.5, 36.1, 36.1, 36.0, 35.4) |
| `populateAlbumArtworkThumbnailsForTracks` | **2.3 ms** (2.5, 2.6, 2.0, 2.3, 1.8) |
| Сумма | **38.3 ms** (39.0, 38.6, 38.2, 38.3, 37.2) |

**Симулятор** (сеяная библиотека 1500 mp3, плейлист `big` 1200 треков,
открытие из списка плейлистов; `[PERF-0808]`-строки из лог-стора
симулятора, `log show --info`):

| Фаза | Значение |
|---|---|
| `loadRows` целиком (begin → firstRowRendered) | **~133 ms** (12:16:35.575 → 12:16:35.708) |
| `loadData` (первый, реальный) | **113.7 ms** |
| `publishTracks` | **0.09 ms** |
| Каскад: второй `loadRows` (onChange после первой публикации) | `loadData` 6.2 ms (early return) |

Подтверждён каскад из диагноза спеки: после первой публикации `tracks`
срабатывает `.onChange(of: libraryManager.tracks)` → второй `loadRows`
параллельно первому (begin 35.698 раньше end 35.706).

### Адаптация к схеме БД

Тикет писался в предположении, что трек можно добавить в плейлист дважды.
Факт кода: `playlist_tracks` имеет составной PK `(playlist_id, track_id)`
(`DMSetup.swift:245`), `PlaylistTrack.insertMany` — `onConflict: .ignore`
(`PlaylistTrack.swift:53`), `savePlaylistAsync` дедуплицирует
(`DMPlaylists.swift:38-47`). Дубликаты на уровне БД невозможны, поэтому
фикстура — 1200 уникальных позиций, ассерты: порядок позиций сохранён,
дубликатов нет. Это же упрощает тикет 06 (обёртка строк и play-by-position
не нужны — согласовано с владельцем плана).

### Инфраструктура

- Скрипт сеяния: `.scratch/playlist-perf/seed-simulator.sh`
  (генератор `.scratch/playlist-perf/generate-library.swift`; вывод в
  `~/scratch/perf-library/`). Пути M3U относительные от
  `Documents/Petrichor-Playlists`: `../Music/Album NNN/000N.mp3`.
- `simctl push` — это push-уведомления, а не копирование файлов; скрипт
  копирует напрямую в контейнер через `simctl get_app_container data`.
- Signpost-инструментация: `Utilities/PerfSignpost.swift` + вставки в
  `TrackListScreen.loadRows`/`trackRow` и `DMPlaylists.loadTracksForPlaylist`/
  `DMQueries.populateAlbumArtworkThumbnailsForTracks`. ОSSignposter
  виден только живому `log stream`/Instruments; для воспроизводимых цифр
  `PerfSignpost.log` пишет `[PERF-0808]`-строки в лог-стор (читаются
  `log show --info --predicate 'subsystem == "org.Petrichor.ios"'`).
- Unit-цифры дополнительно пишутся в
  `tmp/perf-results-0808.txt` контейнера симулятора (stdout тестов
  xcresulttool'ом не отдаётся).
- Грепом: `grep -rn "PERF-0808" --include='*.swift' .` — всё на месте.
