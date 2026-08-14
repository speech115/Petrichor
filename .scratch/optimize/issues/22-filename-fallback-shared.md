# 22 — Filename-fallback: поднять правило в общий слой

**Status:** ready-for-agent
**Blocked by:** —

`iOS/AVAssetMetadataReader.swift:18-46` (`FilenameMetadataFallback.parse`, включая
правило числового префикса `#### - Artist - Title`) богаче, чем fallback общего
слоя в `Managers/Database/DMMetadata.swift:14` (`title?.nilIfEmpty ??
fileURL.deletingPathExtension().lastPathComponent`) и `Models/Core/Track.swift:123` /
`FullTrack.swift:83`. Две разные семантики filename-fallback; канон (`CONTEXT.md`)
документирует числовое правило один раз, а общий слой его не реализует.

## Направление

Поднять числовое правило в общий слой, чтобы оба таргета совпадали.
