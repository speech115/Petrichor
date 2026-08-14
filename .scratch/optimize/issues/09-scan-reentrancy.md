# 09 — `scanLibraryRoot`: reentrancy-guard

**Status:** ready-for-agent
**Blocked by:** —

`iOS/LibraryReconciliation.swift:79-90` `scanLibraryRoot()` не имеет гейта, в
отличие от `reconcileLibrary` (`:30-38`). Кнопка Rescan в `SettingsScreen.swift:96-106`
зовёт его напрямую, защищённого только `!libraryManager.isScanning` — а `isScanning`
переключается в `addFoldersAsync` после `MainActor.run`-хопа (`DMFolders.swift:100-104`).
Rescan, нажатый в окне «гейт пройден — isScanning ещё false», запускает два
конкурентных `scanFoldersForTracks` по одному root.

## Направление

Тот же `isReconcilingLibrary`-гейт внутри самого `scanLibraryRoot`.
