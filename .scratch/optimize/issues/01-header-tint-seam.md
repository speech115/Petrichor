# 01 — headerTint: убрать зависимость от `Views/` и свести три копии

**Status:** ready-for-agent
**Blocked by:** —

`iOS/Library/AlbumPage.swift:106`, `ArtistPage.swift:105`,
`PlaylistDetailScreen.swift:195` вызывают `NowPlayingArtwork.headerTint(...)` из
`Views/Components/NowPlaying/NowPlayingArtwork.swift`. `Views/` по `AGENTS.md` —
только macOS; это залезание в чужой каталог, отмеченное обоими ревьюерами.

Одновременно state+logic tint продублирован байт-в-байт ×3: `@AppStorage("useArtworkColors")`,
`headerDominantColor`, `updateHeaderTint()`, `tintTaskID` — ~27 строк в каждом файле.

## Направление

Один общий хелпер (рядом с `ImageUtils` или в `iOS/Components/`), владеющий
`useArtworkColors` + `headerDominantColor` + `updateHeaderTint`. Убрать import
`Views/` из трёх экранов. `NowPlayingArtwork.headerTint` остаётся macOS-only.
