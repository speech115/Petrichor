# 19 — UI: показывать/копировать относительный путь

**Status:** ready-for-agent
**Blocked by:** —

`iOS/Library/TrackInfoSheet.swift:248` (`value: track.url.path`) и
`iOS/Components/TrackMenuContent.swift:35` (`UIPasteboard.general.string =
track.url.path`) показывают/копируют
`/var/mobile/Containers/<UUID>/Documents/...`. Локально безвредно, но отдаёт
пользователю идентификатор, который проект явно считает нестабильным и
бессмысленным после переустановки/восстановления.

## Направление

Показывать/копировать Documents-относительный путь (`LibraryPathStore.storedPath`).
