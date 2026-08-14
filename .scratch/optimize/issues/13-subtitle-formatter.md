# 13 — «N songs» ×7 — общий форматтер

**Status:** ready-for-agent
**Blocked by:** —

`String(localized: "\(trackCount) songs")` в `AlbumPage.swift:101`,
`ArtistPage.swift:194/196`, `PlaylistDetailScreen.swift:186`,
`PlaylistsTabView.swift:253`, `DiscoverTabView.swift:73`,
`CategoryItemsView.swift:211`. Логика «year • N songs» продублирована verbatim
между `AlbumPage.subtitle` (`:92-103`) и `ArtistPage.albumSubtitle` (`:191-197`).

## Направление

Один форматтер `subtitle(for album/count)` рядом с `PlaylistDisplay`; плюрализация
и year-guard в одном месте.
