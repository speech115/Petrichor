# 11 — `SpotlightIndexer`: три копии sync-алгоритма — в одну

**Status:** ready-for-agent
**Blocked by:** —

`iOS/SpotlightIndexer.swift` — `syncTracks` (`:229-284`), `syncAlbums` (`:380-457`),
`syncArtists` (`:461-537`) структурно идентичны: чтение rows → snapshot-dict →
`toIndex`-diff → удаление stale → chunk по `chunkSize` → `CSSearchableItem` →
сохранение snapshot. Различаются только тип ключа, digest-fingerprint и
item-builder. 538 строк ради трёх копий одного алгоритма.

## Направление

Параметризовать над протоколом `SyncEntity { id, fingerprint, items(database) }`;
три метода схлопываются в один.
