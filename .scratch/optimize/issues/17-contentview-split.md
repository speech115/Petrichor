# 17 — `ContentView`: мёртвый enum + `MiniPlayerAccessory`

**Status:** ready-for-agent
**Blocked by:** —

`iOS/ContentView.swift` (515 строк) держит слишком много: табы, четыре
sheet/`fullScreenCover`/`fileImporter`/`alert`, роутинг `.goToLibraryFilter` и
Spotlight, bindings create-playlist, форматирование import-summary и два
вложенных sub-view.

- `RightSidebarContent` enum (`:18-23`) — мёртвый код в iOS-таргете: на него
  ссылаются только `Views/Main/ContentView.swift` и `Views/Main/PlayerView.swift`
  (macOS). Перенесён из macOS-файла и не используется.
- `MiniPlayerAccessory` (`:339-485`, 147 строк с растеризацией/жестами)
  заслуживает своего файла.

## Направление

Удалить `RightSidebarContent`; `MiniPlayerAccessory` (+ `MiniPlayerProgressLine`)
→ `iOS/Components/`.
