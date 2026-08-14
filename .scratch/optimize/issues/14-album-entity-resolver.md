# 14 — `albumEntity` lookup + destination ×3

**Status:** ready-for-agent
**Blocked by:** —

«in-memory `albumEntities` cache first, then name/DB» повторяется в
`ContentView.albumEntity(for:)` (`:298-303`), `CategoryItemsView.albumEntity(for:)`
(`:107-112`), `SpotlightRouter.albumEntity(forAlbumId:)` (`:60-66`). Маппинг
`.goToLibraryFilter` → artist/album/tracks в `ContentView.destination(for:item:)`
(`:287-296`) и `CategoryItemsView.destination(for:)` (`:96-105`) почти идентичен.

## Направление

Один `AlbumEntity`-резолвер + один `LibraryDestination`-билдер (на `LibraryManager`
или в маленьком роутере).
