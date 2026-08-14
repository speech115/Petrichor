# 12 — `play/playAll/shuffleAll` ×4 — общий хелпер

**Status:** ready-for-agent
**Blocked by:** —

Одинаковый блок в `AlbumPage.swift:160-172`, `ArtistPage.swift:201-213`,
`DiscoverTabView.swift:96-108` (+ `TrackListView.swift:64-66`, `SearchView.swift:282-284`):
```swift
playlistManager.play(track, source: .library(context: tracks))
...
playlistManager.playTrackShuffled(tracks); playlistManager.currentQueueSource = .library
```
`PlaylistDetailScreen.swift:258-270` — `.playlist`-вариант того же.

## Направление

`PlaylistManager.playLibrary(_:context:)` / `shuffleLibrary(_:)` (или небольшой
`LibraryPlayback`-хелпер) — убрать пять копий.
