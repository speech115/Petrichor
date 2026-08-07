# 06 — Экран списка треков: одна копия вместо шести

**What to build:** Скелет экрана списка (loadTask, detached-запрос, onChange,
пустое состояние) и boilerplate вокруг TrackRow перестают копироваться.

Фаза 1 — row-хелпер: расширение PlaylistManager с унифицированным
`play(track:source:)`, покрывающим `playTrack`, `playTrackFromPlaylist`,
`playTrackFromFolder`, и `isCurrent` в одном месте. Умирают 7 копий `isCurrent`
(TrackListView:61-67, ArtistPage:172-178, AlbumPage:156-162, DiscoverView:56-62,
PlaylistDetailScreen:215-221, FolderDetailView:81-87, SearchView:233-239) и
6 копий play-кода (HomeTabView:183-186, TrackListView:69-72, ArtistPage:180-194,
AlbumPage:164-178, DiscoverView:64-67, SearchView:241-244).

Фаза 2 — `TrackListScreen` с source-замыканием (загрузка → секции, через
существующий IndexedListSectionFactory) и вставляемой шапкой. Переезжают
TrackListView, AlbumPage, PlaylistDetailScreen, FolderDetailView.
ArtistPage и CategoryItemsView получают только хелпер загрузки (не выпрямляем
их под формат списка).

Фаза 2b — общий `DetailHeader` (арт + заголовок + подзаголовок + PlayShuffleRow)
вместо трёх копий (ArtistPage:82-104, AlbumPage:66-91, PlaylistDetailScreen:147-166).

**Blocked by:** 05 — скелет строится на новом интерфейсе чтения.

**Status:** ready-for-agent

- [ ] Фаза 1: один `play(track:source:)` и один `isCurrent`; 7+6 копий удалены
- [ ] Фаза 2: четыре экрана используют TrackListScreen; ArtistPage/CategoryItemsView — хелпер загрузки
- [ ] Фаза 2b: три шапки — один DetailHeader
- [ ] Группировка (годы, диски) и пустые состояния не изменились визуально
- [ ] Оба таргета собираются; экраны проверены на симуляторе
