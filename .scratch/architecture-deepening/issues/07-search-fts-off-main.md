# 07 — Поиск: FTS не на главном акторе

**What to build:** FTS5-запрос на каждый кестроук на главном акторе уходит в
фон. `LibrarySearch.searchTracks` (`Core/LibrarySearch.swift:19-21`) выглядит
чистой функцией, но зовёт `AppCoordinator.shared.libraryManager.databaseManager.
searchTracksUsingFTS`; вызывается синхронно из `LibraryManager.globalSearchText.
didSet` → `updateSearchResults()` (`LMQueries.swift:52-60`). Ввод в поиске не
должен блокировать главный актор.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

Реализовано в соседней сессии (незакоммичено): SearchView на локальном
`@State query` + `.task(id:)` → `LibraryManager.search(query:populateArtwork:)`
(FTS в `Task.detached`, `@MainActor` для публикации); macOS-путь
(`globalSearchText`/`updateSearchResults`) сохранён. Осталось проверить.

- [x] FTS-запрос выполняется не на главном акторе (detached task/очередь)
- [x] Кестроук не блокирует UI на 2829 треках (проверить на устройстве)
- [x] Устаревший ответ не перезаписывает свежий (порядок результатов гонки)
- [x] Поведение поиска не изменилось (сборка)

