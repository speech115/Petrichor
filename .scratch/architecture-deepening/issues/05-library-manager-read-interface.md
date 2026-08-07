# 05 — LibraryManager: полный интерфейс чтения

**What to build:** Прямые пути из вьюх в DatabaseManager сворачиваются в
интерфейс LibraryManager (extension-файлы LM*, как LMQueries).

Подготовка уже сделана в соседней сессии (незакоммичено): `populateArtwork:
Bool` протянут через запросы базы (getTracksForArtistEntity/AlbumEntity/Folder,
FTS, loadTracksForPlaylist, smart-playlist) и обёртки (getTracksInFolder,
getTracksBy); экраны передают `false` и делают батч-проход сами. Оставшаяся
работа — сам переезд вызовов на менеджер-обёртки: обёртки формулируют
потребность экрана («треки альбома с миниатюрами»), вьюхи не знают имени
DatabaseManager. Точки вызова:

- `iOS/Library/TrackListView.swift:104-119` — все треки + миниатюры
- `iOS/Library/ArtistPage.swift:209-212` — треки артиста (сейчас
  `databaseManager.getTracksForArtistEntity(name, populateArtwork: false)` +
  батч), арт и био
- `iOS/Library/AlbumPage.swift:193-195` — треки альбома (тот же паттерн)
- `iOS/Home/HomeTabView.swift:213-221` — недавно прослушанные, недавно
  добавленные, превью плейлистов
- `iOS/Folders/FolderDetailView.swift:103-107` — проход миниатюр
- `iOS/Components/TrackRow.swift:150-186` — пер-строчный фолбэк обложки и
  `TrackRowArtworkStore` NSCache: контракт «строки приходят наполненными»
  обязателен для всех списков, включая поиск (уже так: `search(query:
  populateArtwork: false)` + батч); фолбэк и кэш умирают
- `iOS/Playlists/PlaylistDetailScreen.swift:184-191` — вьюха перестаёт
  мутировать `playlistManager.playlists[index].tracks` через
  `playlistManager.libraryManager?.databaseManager`: `loadPlaylistTracks` /
  `loadSmartPlaylistTracks` делают проход миниатюр сами (внутри менеджера)

Другие менеджеры (PlaybackManager, PlaylistManager, ScrobbleManager,
ArtistBioManager) сохраняют прямой доступ к базе — шов ограничивает слой вьюх.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [x] Ни одна вьюха не обращается к `databaseManager` (0 вызовов из iOS/ и Views/)
- [x] Вьюхи не мутируют состояние менеджеров как обходной путь (PlaylistDetailScreen)
- [x] TrackRow не имеет пути в БД и не держит NSCache
- [x] Поиск наполняет миниатюры при фильтрации
- [x] Мёртвые функции базы без вызовов удалены (getTracksByArtist, getAllAlbums и т.п. — список в обзоре)
- [x] Оба таргета собираются; списки рендерятся с обложками как раньше
