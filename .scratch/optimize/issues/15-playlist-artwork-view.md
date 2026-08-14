# 15 — Playlist-artwork fallback ×2 — общая вью

**Status:** ready-for-agent
**Blocked by:** —

Одинаковый трёхступенчатый fallback с одним ключом в
`PlaylistsTabView.swift:266-278` (row) и `PlaylistDetailScreen.swift:162-180`
(header):
```swift
if playlist.coverArtworkData != nil { ArtworkTile(...) }
else if let cover = PlaylistCover.of(playlist) { PlaylistCoverView(cover: cover) }
else { ArtworkMosaic(covers: PlaylistCover.mosaicCovers(from: tracks)) }
```
Различается только размер кадра (48 vs 280).

## Направление

`PlaylistArtworkView(playlist:tracks:cornerRadius:)` — один компонент на оба места.
