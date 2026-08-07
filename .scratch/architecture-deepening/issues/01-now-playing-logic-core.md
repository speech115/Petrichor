# 01 — Now Playing логика в Core

**What to build:** Платформенно-нейтральная логика Now Playing переезжает из
скопированных панелей в чистые модули `Core/NowPlaying/`:

- Тайминг лирики: текущая строка по времени (сейчас продублирован в
  `iOS/Components/NowPlayingLyricsPanel.swift` и макошном
  `Views/Main/TrackLyricsView.swift`).
- Seek-математика: drag/tap слайдера и клампинг длительности (сейчас в
  `Views/Components/NowPlaying/NowPlayingProgressBar.swift` с признанием в
  шапке файла о дублировании `PlayerView.progressSlider`).

Мигрируют обе платформы — иначе дублирование не убрано, а дополнено третьей
копией. Строка очереди — вне скоупа (реордер — платформенные жесты).

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [x] `Core/NowPlaying/` содержит чистые модули тайминга лирики и seek-математики
- [x] iOS `NowPlayingLyricsPanel` и макош `TrackLyricsView` используют один модуль
- [x] iOS прогресс-бар и макош `PlayerView.progressSlider` используют одну seek-математику
- [x] Модули покрыты тестами на швах (тесты — только на швах, правило репо)
- [x] Оба таргета собираются; поведение лирики и слайдера не изменилось
