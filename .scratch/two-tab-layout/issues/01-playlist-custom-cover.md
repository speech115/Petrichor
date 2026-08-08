# 01 — Кастомная обложка плейлиста вместо мозаики

**What to build:** Карточка плейлиста на iOS показывает мозаику 2×2 из первых
четырёх треков и игнорирует собственную обложку плейлиста. Мак её показывает —
поэтому в его сайдбаре видны значки VK, Яндекса и Spotify, а на телефоне все
пятнадцать плейлистов выглядят одинаковой серой мозаикой.

Причина: `iOS/Home/HomeTabView.swift`, `PlaylistCard` кладёт в `ArtworkMosaic`
только `previewTracks`. Готовый путь `Playlist.artworkData`
(`Models/Core/Playlist.swift`), который начинается с проверки
`coverArtworkData`, не вызывается.

Сделать: если у плейлиста есть `coverArtworkData` — показывать её через
`ArtworkTile`; иначе прежняя мозаика из превью-треков. То же правило применить в
шапке `iOS/Playlists/PlaylistDetailScreen.swift` (функция `header`, сейчас там
безусловный `ArtworkMosaic` 240×240).

Не трогать: сам `Playlist.artworkData` и `PlaylistArtworkCache` — они работают,
их просто не зовут. Коллаж-рендер (`renderCollageArtwork`) в iOS-карточках не
нужен, мозаика собирается вью.

Спека: `.scratch/two-tab-layout/spec.md`, раздел «Playlists — вкладка».

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

## Проверка

Симулятор с реальной библиотекой: плейлисты «ВКонтакте», «Яндекс Музыка»,
«Spotify — Liked Songs» показывают свои обложки; «Все треки» и «Любимые треки»
без кастомной обложки остаются мозаикой.
