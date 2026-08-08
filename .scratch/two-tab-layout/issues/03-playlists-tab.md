# 03 — Вкладка Playlists: список строк 56 pt

**What to build:** Новый файл `iOS/Playlists/PlaylistsTabView.swift` — корень
второй вкладки. Список всех плейлистов строками 56 pt.

- Порядок как в маковом сайдбаре: смарт-плейлисты сверху (Favorites, Top 25 Most
  Played, Top 25 Recently Played), затем пользовательские по алфавиту. Готовая
  логика есть — `displayPlaylists` в `iOS/Home/HomeTabView.swift`, перенести её
  сюда.
- Строка: обложка 56 pt (правило из тикета 01 — своя обложка, иначе мозаика),
  имя через `DefaultPlaylists.displayName(for:)`, подпись «N songs».
- Секция пользовательских отделена подзаголовком «My Playlists».
- Тулбар: импорт M3U (`showingPlaylistImporter`) и «+»
  (`playlistManager.showCreatePlaylistModal()`) — переезжают из навбара Home.
  `CreatePlaylistSheet` и `.fileImporter` уже существуют, переиспользовать.
- Тап ведёт в существующий `PlaylistDetailScreen` через `navigationDestination`
  вкладки.

Сетку плейлистов из `HomeTabView` удалить вместе с `PlaylistCard` — на Home её
больше нет (см. тикет 06).

Крупный сворачивающийся заголовок — как на других верхнеуровневых экранах
(сделано в прошлой фазе, тикет `apple-music-design/03`).

Спека: `.scratch/two-tab-layout/spec.md`, раздел «Playlists — вкладка».

**Blocked by:** 01, 02

**Status:** ready-for-agent

## Проверка

Симулятор: 15 плейлистов в правильном порядке, у источников свои обложки,
счётчики совпадают с маком, создание и импорт плейлиста работают из новой
вкладки, открытие плейлиста ведёт на детальный экран.
