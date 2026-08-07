# 02 — Инъектируемая база и модуль матчинга M3U

**What to build:** Два изменения, открывающих спека-тесты на швах.

1. `DatabaseManager.init(pool: DatabasePool)` вместо открытия Application
   Support внутри инита (`Managers/Database/DatabaseManager.swift:29-64`).
   Путь собирает вызывающая сторона (AppCoordinator или фабрика). Тесты
   передают in-memory пул.

2. Матчинг M3U выделяется из `Managers/Playlist/PMImportExport.swift`
   (`matchTracksToLibrary`, :240-305) в модуль `Core/` с одним методом
   `resolveTracks(for: [M3UEntry])`. Внутри — трёхстадийный фолбэк (путь →
   точное имя → нормализованное имя) и политика отказа от неоднозначного
   (сейчас продублирована в `findTracksByFilenames` DMQueries:922-933 и
   `M3UFilenameMatcher.resolveAll`). Артворк-наполнение
   (`populateAlbumArtworkForTracks` в `processM3UContent`) уходит из импорта —
   это забота вызывающей стороны.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] `DatabaseManager(pool:)` существует; прод-путь собирается вне менеджера
- [ ] Спека-тесты «сборка библиотеки из папки» и «полный импорт M3U» работают
      против in-memory пула и временной папки (раньше были невозможны —
      см. FolderScanTests/PathQueryTests, переписывающие предикаты)
- [ ] `resolveTracks(for:)` в Core; политика неоднозначности в одном месте
- [ ] Импорт M3U не наполняет обложки сам; вызывающая сторона решает
- [ ] LibraryManager и его `fatalError` не тронуты
- [ ] Оба таргета собираются; импорт M3U на устройстве работает как раньше
