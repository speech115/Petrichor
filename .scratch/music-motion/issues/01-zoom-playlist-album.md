# 01 — Zoom open плейлиста и альбома

**What to build:** Тап по плейлисту или альбому зумит destination из
источника (`matchedTransitionSource` + `.navigationTransition(.zoom)`),
включая строки списка плейлистов и карточки/полки альбомов.

**Status:** ready-for-human

Спека: `.scratch/music-motion/spec.md`. Artist zoom — вне скоупа.

## Comments

### 2026-08-13

Код: `DetailZoomTransition.swift` + wiring в Home/Playlists/Search/Category/Artist.
Визуальная приёмка — на симуляторе/устройстве (cloud без xcodebuild).
