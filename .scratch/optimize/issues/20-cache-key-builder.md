# 20 — Магические cache-key строки — в один билдер

**Status:** ready-for-agent
**Blocked by:** —

Одни и те же литеральные ключи чеканятся независимо: `"album-\(id)"`
(`AlbumPage.swift:123`, `CategoryItemsView.swift:198`, `SearchView.swift:237`,
`TrackRow.swift:101`), `"now-playing-\(id)"` (`ContentView.swift:475`,
`NowPlayingScreen.swift:320`), `"playlist-\(id)"`, `"artist-detail-\(name)"`,
`"track-info-\(id)"`. `AlbumPage.swift:121-123` даже документирует совпадение с
Now Playing-ключом по строке ради тёплого color-cache. Опечатка в любой строке
молча разводит кеши.

## Направление

Один `ArtworkCacheKey`-билдер, общий для обоих кешей.
