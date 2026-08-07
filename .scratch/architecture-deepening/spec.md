# Углубление архитектуры: интерфейсы чтения, реконсиляция, Now Playing

Источник: обзор `improve-codebase-architecture` (2026-08-07), прогнан через
грилл. Шесть кандидатов на углубление + один отдельный фикс поиска. Каждое
решение ниже принято явно и является каноном для тикетов.

Словарь архитектуры: модуль, интерфейс, глубина, шов, локальность, рычаг —
термины `/codebase-design`. Термины домена — из `CONTEXT.md`.

## C1 — LibraryManager: полный интерфейс чтения (тикет 05)

- Достройка extension-файлами на LibraryManager (паттерн LM*); вьюхи не знают
  имени DatabaseManager.
- Обёртки формулируют потребность экрана («треки альбома с миниатюрами»);
  `populateArtwork: Bool` остаётся деталью базы.
- Контракт миниатюр: каждый список строк приходит наполненным, включая поиск
  (кэш-треки наполняются при фильтрации); у TrackRow нет пути в БД — ни
  прямого, ни через NSCache (`TrackRowArtworkStore` умирает).
- Другие менеджеры (PlaybackManager, PlaylistManager, ScrobbleManager,
  ArtistBioManager) сохраняют прямой доступ к базе — шов ограничивает слой
  вьюх.
- FTS-фикс — отдельный тикет 07, не входит в C1.

## C2 — Реконсиляция: один модуль, один владелец инварианта (тикет 03)

- `removeDeletedTracks` уходит целиком, с обеих платформ: строки переживают
  пропажу файла, отметки «недоступен» нет, уведомления «Removed X missing
  tracks» умирают.
- Инвариант записан в ADR-0001 и CONTEXT.md (сделано при планировании).
- iOS-реконсиляция (`reconcileLibrary`, `scanLibraryRoot`,
  `importLibraryPlaylistsIfNeeded`) переезжает из `#else` ветки
  `#if os(macOS)` в LMFolders.swift в файл целевого таргета `iOS/`.
- Триггеры (AppCoordinator `#if os(iOS)` блок, scenePhase) сохраняются.

## C3 — Now Playing логика в Core (тикет 01)

- `Core/NowPlaying/`: тайминг лирики (текущая строка по времени) и
  seek-математика (drag/tap, клампинг длительности) — чистые функции.
- Мигрируют обе платформы: iOS-панели и макошные `TrackLyricsView` /
  `PlayerView.progressSlider`. Дублирование убрано, а не дополнено третьей
  копией.
- Строка очереди — вне скоупа (реордер — платформенные жесты).

## C4 — Экран списка треков (тикет 06)

- Фаза 1: row-хелпер — расширение PlaylistManager с унифицированным
  `play(track:source:)` (покрывает `playTrack`, `playTrackFromPlaylist`,
  `playTrackFromFolder`) и `isCurrent` в одном месте (7 копий умирают).
- Фаза 2: `TrackListScreen` с source-замыканием (загрузка → секции) и
  вставляемой шапкой — для TrackListView, AlbumPage, PlaylistDetailScreen,
  FolderDetailView. ArtistPage и CategoryItemsView получают только хелпер
  загрузки (не выпрямляем их под формат списка).
- Фаза 2b: общий `DetailHeader` (арт + заголовок + подзаголовок +
  PlayShuffleRow) вместо трёх копий в ArtistPage/AlbumPage/PlaylistDetailScreen.

## C5 — Инъектируемая база (тикет 02)

- `DatabaseManager.init(pool: DatabasePool)`; путь Application Support
  собирает вызывающая сторона (AppCoordinator/фабрика); тесты передают
  in-memory пул.
- Матчинг M3U — модуль в Core с одним методом `resolveTracks(for: [M3UEntry])`;
  политика (путь → точное имя → нормализованное имя, отказ от неоднозначного)
  внутри модуля; артворк-наполнение — забота вызывающей стороны.
- LibraryManager и его `fatalError` не трогаются; спека-тесты («сборка из
  папки», «полный M3U-импорт») целятся в DatabaseManager + временную папку.

## C6 — Now Playing публикация в адаптере (тикет 04)

- AVQueuePlayerBackend пере-публикует метаданные на собственных событиях
  (timeControlStatus, seek) вместо одноразовой публикации; менеджер не зовёт
  вручную.
- Тест шва в QueueBackendTests: «пауза пере-публикует метаданные».

## Порядок исполнения

03 blocked by 02 · 06 blocked by 05 · остальные независимы.

C3 (01) → C5 (02) → C2 (03) → C6 (04) → C1 (05) → C4 (06); FTS-фикс (07)
независим.

## Соседняя сессия (2026-08-07, незакоммичено)

Перепроверка плана перед исполнением выявила чужую незакоммиченную работу
в том же дереве:

- Тикет 07 (поиск) — **реализован**: SearchView переведён на локальный
  `@State query` + `.task(id:)` → `LibraryManager.search(query:populateArtwork:)`
  (FTS в `Task.detached`); macOS-путь (`globalSearchText`/`updateSearchResults`)
  сохранён. Осталась проверка на устройстве.
- Тикет 05 — **подготовлен частично**: `populateArtwork: Bool` протянут через
  запросы базы (getTracksForArtistEntity/AlbumEntity/Folder, FTS,
  loadTracksForPlaylist, smart-playlist) и менеджер-обёртки; экраны передают
  `false` и делают батч-проход сами. Сам переезд вызовов на менеджер-обёртки
  не сделан: прямые вызовы `databaseManager` из вьюх на месте, пер-строчный
  фолбэк TrackRow жив, PlaylistDetailScreen мутирует состояние менеджера.
- Бонусы вне тикетов: синхронная вставка текущего трека + асинхронный долив
  lookahead-окна в AVQueuePlayerBackend (латентность старта), кэш декодированной
  обложки в PlaybackManager (`nowPlayingArtworkImage`), хардненинг
  QueueBackendTests (`waitForPreload`), правки AGENTS.md/.gitignore.

Перед исполнением планных тикетов чужую работу желательно закоммитить, чтобы
дифы тикетов не смешивались.

## Вне скоупа

- Табы: расхождение спеку-код (Playlists → Media) — документальный долг,
  чинится отдельно.
- Углубление семантики шва воспроизведения («что дальше после финиша X в
  режиме R») — Speculative, упирается в repeat-политику PlaylistManager.
