# 16 — `NowPlayingScreen`: вынести volume slider + AirPlay

**Status:** ready-for-agent
**Blocked by:** —

`iOS/Player/NowPlayingScreen.swift` (628 строк) держит композицию экрана и два
UIKit `UIViewRepresentable` в одном файле: `SystemVolumeSlider` (`:578-604`) и
`AirPlayButton` (`:610-628`). Это переиспользуемые платформенные контролы, не
связанные с layout экрана, lifecycle палитры и state-машиной панели
(`presentPanel`/`dismissPanel`/`updatePanelDrag`/`finishPanelDrag`, `:494-559`).

## Направление

`SystemVolumeSlider` + `AirPlayButton` → `iOS/Components/`; панельный lifecycle
можно вынести в `NowPlayingPanel`-хост.
