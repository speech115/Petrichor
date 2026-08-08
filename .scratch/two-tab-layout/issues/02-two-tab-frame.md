# 02 — Каркас: две вкладки, поиск кнопкой, настройки в Home

**What to build:** `iOS/ContentView.swift` перестраивается на две вкладки —
**Home** (`Icons.musicNoteHouse`) и **Playlists** (`Icons.musicNoteList`) — плюс
существующий `Tab(role: .search)`, который iOS 26 рисует круглой кнопкой справа
от пилюли.

1. Из `IOSSection` убрать `.media`, добавить `.playlists`. Вкладка Playlists
   пока может показывать заглушку — её содержимое делает тикет 03.
2. Удалить `iOS/Library/MediaLibraryView.swift`. Шестерёнку настроек из его
   навбара перенести в топ-трейлинг навбара Home
   (`iOS/Home/HomeTabView.swift`); биндинг `showingSettings` и `.sheet` в
   `ContentView` уже есть.
3. Кнопки импорта M3U и «+» из навбара Home переезжают во вкладку Playlists
   (тикет 03). До него их можно оставить в Home.
4. `iOS/Library/LibraryDestination.swift`: убрать `.category(...)` для жанров и
   годов и осиротевший `.discover`, если после переноса он никем не строится.
   Стек Home сохраняет `.allTracks`, `.artist`, `.album`, `.tracks`.
5. `.goToLibraryFilter` в `ContentView` сейчас переключает на `.media` и толкает
   в `mediaPath` — переадресовать в стек Home.
6. `Resources/Localizable.xcstrings`: строка «All Tracks» → «Songs». Только
   английское значение; `zh-Hans` не трогать.

**Строку `.searchable` в Home не добавлять** — вход в поиск один, через кнопку в
таб-баре.

**Осторожно:** `LibraryFilterType.genres` и `.years` — общий enum, который
используют мак (`Views/Home/HomeView.swift`) и слои `Managers`/`Models`
(`DMCategoryQueries`, `AutomationEntities`, `Track`, `Album`, `Artist`).
**Кейсы enum удалять нельзя** — это сломает macOS-таргет. Удаляются только
iOS-точки входа. `CategoryItemsView` остаётся: он нужен артистам и альбомам.

Спека: `.scratch/two-tab-layout/spec.md`, раздел «Каркас — две вкладки».

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

## Проверка

Собираются **оба** таргета:

```
xcodebuild -scheme PetrichoriOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build
xcodebuild -scheme Petrichor build
```

В симуляторе: две вкладки и круглая лупа, поиск работает с обеих вкладок,
шестерёнка открывает настройки, переход «показать артиста» из контекстного меню
трека приводит на страницу артиста внутри Home.
