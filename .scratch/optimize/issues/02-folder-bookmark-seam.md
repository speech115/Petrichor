# 02 — Bookmark-политика из `Folder` — в шов `LibraryPathStore`

**Status:** ready-for-agent
**Blocked by:** —

`Models/Core/Folder.swift:95-99`:
```swift
#if os(iOS)
container[Columns.bookmarkData] = nil
#else
container[Columns.bookmarkData] = bookmarkData
#endif
```

Создание/резолв bookmark-опций уже живут в `LibraryPathStore` (`:23-38`); решение
«на iOS bookmark-data не персистим» — дело того же шва, а не `Folder.encode(to:)`.
Это ровно «разветвление по месту вызова», которое запрещает правило пяти швов.

## Направление

`LibraryPathStore.storedBookmarkData(for:)` возвращает `nil` на iOS; `Folder`
вызывает его безусловно, без `#if os`.
