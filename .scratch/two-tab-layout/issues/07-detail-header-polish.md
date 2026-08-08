# 07 — Шапка детальных экранов: подкраска, заголовок, равные кнопки

**What to build:** `iOS/Components/DetailHeader.swift` — общая шапка альбома,
артиста и плейлиста. Четыре правки:

1. **Фон подкрашивается цветом обложки.** Готовый расчёт —
   `NowPlayingArtwork.tint(for:useArtworkTint:)` в
   `Views/Components/NowPlaying/NowPlayingArtwork.swift`. Файл лежит в `Views/`,
   но уже вызывается из `iOS/ContentView.swift` — прецедент есть, новый шов
   заводить не нужно. Градиент от цвета сверху к прозрачному, высота ~340 pt,
   под контентом. Уважать `useArtworkColors` из `@AppStorage`, как это делает
   `ContentView`.
2. **Заголовок уезжает из навбара под обложку.** У экранов
   `navigationBarTitleDisplayMode(.inline)`, название и подзаголовок рисует сама
   шапка. Освобождается ~96 pt над картинкой.
3. **Подпись с длительностью.** `iOS/Playlists/PlaylistDetailScreen.swift`,
   функция `header`: сейчас «N songs», нужно «N songs · длительность».
   `Playlist.formattedTotalDuration` уже посчитан и показан на маке.
4. **Play и Shuffle равны по весу.** `iOS/Components/PlayShuffleRow.swift`:
   сейчас `borderedProminent` против `bordered`. Обе — `tinted`-капсулы на
   подложке акцента. На маке они тоже равны, а на 1 286 треках нажимают Shuffle.

Правки общие для альбома, артиста и плейлиста — все три используют
`DetailHeader`.

Спека: `.scratch/two-tab-layout/spec.md`, раздел «Детальные страницы».

**Blocked by:** 02

**Status:** ready-for-agent

## Проверка

Симулятор в светлой и тёмной теме: подкраска читается на обоих фонах и не
съедает контраст текста; при выключенном `useArtworkColors` фон обычный.
