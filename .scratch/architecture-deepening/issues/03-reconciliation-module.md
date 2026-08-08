# 03 — Реконсиляция: один модуль, один владелец инварианта

**What to build:** Инвариант «строка переживает пропажу файла» (ADR-0001,
записан при планировании) приводится в соответствие с кодом, а iOS-реконсиляция
уходит из платформенной ветки общего файла.

1. `removeDeletedTracks` (`Managers/Database/DMFolders.swift:673-727`) удаляется
   вместе с вызовом в `scanSingleFolder` (:572) — на обеих платформах.
   Умирают уведомления «Removed X missing tracks» и «Folder is now empty»,
   параметр `hasRemainingFiles`, счётчики `incrementTracksRemoved`.
   Комментарий в `libraryContentsDiffer` (:426-431) становится правдой.
   Отметку «недоступен» не вводим — ошибка при воспроизведении как сегодня.

2. iOS-реконсиляция переезжает из `#else` ветки `#if os(macOS)` в
   `Managers/Library/LMFolders.swift:14-253` в файл целевого таргета `iOS/`
   (как AVQueuePlayerBackend): `addFolder(urls:)` (iOS-версия), `reconcileLibrary()`,
   `scanLibraryRoot()`, `importLibraryPlaylistsIfNeeded()`. Триггеры
   (AppCoordinator `#if os(iOS)` блок :55-73, scenePhase в PetrichorApp)
   сохраняются.

**Blocked by:** 02 — матчинг M3U переезжает уже в чистом виде (модуль из 02).

**Status:** ready-for-agent

- [x] `removeDeletedTracks` и связанные уведомления/счётчики удалены
- [x] Строки пропавших файлов переживают полный скан (тест на шве: папка →
      удаление файла → скан → строка на месте)
- [x] iOS-реконсиляция живёт в файле `iOS/`; в LMFolders остались только macOS-входы (AppKit import, NSOpenPanel `addFolder`)
- [x] Триггеры реконсиляции работают (запуск, фон, «Пересканировать»)
- [x] Оба таргета собираются
