# 02 — Потоковая корректность `loadPlaylistTracks`

Status: resolved
Blocked by: 01

## Проблема

`PlaylistManager.loadPlaylistTracks(for:)`
(`Managers/Playlist/PlaylistManager.swift:135-149`) — синхронный метод без
изоляции: читает БД и затем мутирует `@Published var playlists` (строка 147).
Вызывается он из `Task.detached(priority: .userInitiated)`
(`iOS/Library/TrackListScreen.swift:118-121`, замыкание `load` приходит из
`iOS/Playlists/PlaylistDetailScreen.swift:36` → `loadTracks(playlist)`,
см. также :158-167). Итог: SwiftUI получает изменение observable-состояния с
фонового потока — фризы, runtime warning «Publishing changes from background
threads», потенциальная гонка с чтением `playlists` на главном потоке
(`PlaylistDetailScreen.swift:27-29`, `iOS/Home/HomeTabView.swift:122-131`).

Смарт-плейлисты уже делают правильно: `loadSmartPlaylistTracks`
(`Managers/Playlist/PMSmartPlaylists.swift:119-163`) — async, все мутации
`playlists` через `await MainActor.run` (:155-162).

## Что сделать

Привести обычный путь к симметрии со смарт-путём:

- Сделать `loadPlaylistTracks(for:) async`: чтение БД
  (`loadTracksForPlaylist` + `populateAlbumArtworkThumbnailsForTracks`)
  остаётся вне главного потока, обе проверки/мутации `playlists`
  (строки 136-141 и 146-148) — под `await MainActor.run` (guard читает
  `playlists` — это тоже доступ к published-состоянию).
- Обновить вызовы. Известные: `PlaylistDetailScreen.loadTracks`
  (`iOS/Playlists/PlaylistDetailScreen.swift:158-167`) и
  `getPlaylistTracks` (`PlaylistManager.swift:152+`). Найти остальные:
  `grep -rn "loadPlaylistTracks\|getPlaylistTracks" --include='*.swift' .`
  Синхронный `getPlaylistTracks` либо тоже становится async, либо удаляется,
  если все вызовы уходят на async-путь — слоёв совместимости не оставлять.
- macOS-таргет (`Views/`) тоже собирается с этим менеджером — проверить его
  вызовы тем же grep-ом и обновить.

## Критерии приёмки

- [ ] `grep -rn "playlists\[" Managers/Playlist/` — ни одной мутации
      `playlists` вне `MainActor`.
- [ ] Запуск на симуляторе с большим плейлистом (сеяние из тикета 01):
      в логах нет «Publishing changes from background threads».
- [ ] Оба таргета собираются: схема `PetrichoriOS` и схема `Petrichor` (macOS).
- [ ] `xcodebuild test` зелёный.
- [ ] Цифры signpost «publish-фаза» из тикета 01 сняты повторно и записаны
      в Comments (ожидание: publish уходит на main без блокировки data-фазы).

## Comments

### Что сделано (2026-08-08)

- `PlaylistManager.loadPlaylistTracks(for:)` → `async`: guard-проверка и
  мутация `playlists[index].tracks` под `await MainActor.run`, чтение БД
  осталось вне главного потока (зеркало `loadSmartPlaylistTracks`).
- `getPlaylistTracks` → `async`, делегирует `loadPlaylistTracks` (побочный
  выигрыш: экспорт M3U и App Intents больше не тянут полноразмерные
  BLOB-обложки — раньше `getPlaylistTracks` звал `loadTracksForPlaylist`
  с дефолтным `populateArtwork: true`).
- Вызовы обновлены: `iOS/Playlists/PlaylistDetailScreen.swift:163`
  (`await`), macOS `Views/Playlists/PlaylistDetailView.swift:451` (Task),
  `PMImportExport.swift:316` (убран `MainActor.run`-обёрток),
  `Managers/Automation/AMContent.swift` + `AutomationIntents.swift`
  (playPlaylist/enqueuePlaylist → async).
- `grep -rn "playlists\[" Managers/Playlist/` — в пути загрузки
  (`loadPlaylistTracks`/`getPlaylistTracks`/hot-рефреш) мутаций вне
  MainActor нет; оставшиеся прямые мутации (loadPlaylists, reorder,
  create/update smart) вызываются с главного потока как и раньше.

### Замеры симулятора (повтор после фикса)

| Фаза | До (12:16) | После (12:30) |
|---|---|---|
| `loadData` (первый, реальный) | 113.7 ms | **99.9 ms** |
| `publishTracks` | 0.086 ms | **0.05 ms** |
| Каскад `loadRows` (onChange) | 6.2 ms | 0.21 ms (early return) |

В логах симулятора после открытия `big` нет «Publishing changes from
background threads» (предикат `eventMessage CONTAINS "Publishing changes"`).

### Сборка

- Оба таргета собираются (macOS — с `CODE_SIGNING_ALLOWED=NO`, подпись на
  машине отсутствует независимо от правок); `xcodebuild test` — 65 тестов
  зелёные. Новых предупреждений нет (Swift 6-ворнинги захвата `var` в
  async-замыканиях устранены).
