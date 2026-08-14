# 05 — `ImageUtils`: `#if os` — в `PlatformShims`

**Status:** ready-for-agent
**Blocked by:** —

`Utilities/ImageUtils.swift` — пять платформенных веток вне пяти швов:
`:5-9` (import), `:329` (`backgroundGradientColors`), `:442` (`systemFont`),
`:599` (`platformColor`), `:612` (`encodeJPEGPlatform`). Каждая
пере-реализует NSImage/UIImage-обработку вместо того, чтобы идти через
`PlatformImage`/`PlatformColor` (многое уже есть в `PlatformShims.swift`).

## Направление

Провести ветки через шимы `PlatformShims`; в `ImageUtils` оставить только
кросс-платформенную логику. (`#if arch(x86_64)` на `:31/:623` — отдельная
документированная история, не трогать.)
