# 07 — Кэш декодированных обложек в строках списка

Status: resolved
Blocked by: 01

## Проблема

`ArtworkTile` (`iOS/Components/ArtworkTile.swift:18-34`) делает
`UIImage(data: data)` синхронно в `body`. Каждый проход строки через экран
при скролле — повторный JPEG/HEIC-декод на главном потоке. Кэшей на этом
пути нет (существующие `NSCache`-кэши живут в macOS-вьюхах `Views/` и в
`ImageUtils` для цветов, не для строк iOS).

## Что сделать

- Новый файл `iOS/Components/RowArtworkCache.swift`:
  `NSCache<NSString, UIImage>` синглтон; `countLimit` ~500. Ключ — данные
  трека уже содержат стабильную привязку: использовать `albumId` (обложки
  строк — альбомные thumbnails, см. `Models/Core/Track.swift:227-232`);
  для треков без `albumId` — не кэшировать (редкий случай).
- `ArtworkTile` получает опциональный `cacheKey: String?` (передаёт
  `TrackRow`, `iOS/Components/TrackRow.swift`, из `track.albumId`).
  Логика body:
  1) hit в кэше → отдать синхронно (без мерцания);
  2) miss → плейсхолдер + `.task(id: cacheKey)`: декод
     `UIImage(data:)?.preparingForDisplay()` вне главного потока, положить
     в кэш, обновить `@State`-картинку. `task(id:)` сам отменяет устаревший
     декод при переиспользовании строки — руками ничего не отслеживать.
- Остальные места с `UIImage(data:)` в iOS-строках/карточках найти grep-ом
  `grep -rn "UIImage(data:" iOS/` и перевести на тот же тайл/кэш, если они
  рендерятся в прокручиваемых списках (Home-карточки плейлистов уже имеют
  свой `PlaylistArtworkCache` в `Models/Core/Playlist.swift` — не трогать).

Thumbnails в БД ~маленькие (сжатие описано в
`Utilities/ImageUtils.swift:compressImage`), поэтому память кэша при
countLimit 500 — единицы мегабайт; лимит не конфигурировать (правило
простейшей реализации).

## Критерии приёмки

- [ ] Быстрый скролл большого плейлиста на симуляторе: обложки не мигают,
      не появляются «чужие» обложки на переиспользованных строках.
- [ ] Signpost/Instruments (или счётчик декодов с `[PERF-0808]`-логом):
      повторный проход одних и тех же строк не декодирует заново.
- [ ] Оба таргета собираются, `xcodebuild test` зелёный.

## Comments

### Реализация (2026-08-08)

- Новый `iOS/Components/RowArtworkCache.swift`: `NSCache<NSString, UIImage>`
  синглтон, `countLimit = 500`, ключ — `albumId`.
- `ArtworkTile`: опциональный `cacheKey`; hit → синхронно из кэша, miss →
  плейсхолдер + `.task(id: cacheKey)` с декодом `UIImage(data:)?.preparingForDisplay()`
  в `Task.detached(priority: .utility)`; результат кладётся в кэш и в
  `@State`. `.id(cacheKey ?? data-hash)` сбрасывает состояние при переиспользовании
  строки под другую обложку — «чужие» картинки не мигают.
- `TrackRow.artworkView` и `ArtistPage.albumArtwork` передают
  `cacheKey: albumId.map(String.init)`.
- Остальные `UIImage(data:)` в `iOS/`: `NowPlayingPublisher.swift:34` (обложка
  Now Playing), `AlbumPage.swift:61` и `ArtistPage.swift:94` (одиночные
  заголовки, не списки) — не трогал.

### Проверка на симуляторе

Сеяная библиотека + 100 альбомов с реальными thumbnail-обложками
(записаны прямо в БД контейнера). Открыл `big`, скролл вниз и обратно,
счётчик `[PERF-0808] artworkDecoded`:

| Момент | total |
|---|---|
| Первый экран | 30 |
| После скролла вниз (~800px) | 34 (только новые альбомы) |
| После скролла обратно к началу | **34 (0 повторных декодов)** |

Повторный проход одних и тех же строк изображения берёт из кэша, чужие
обложки на переиспользованных строках не появляются (все 15 треков Album
001 — один альбомный ключ, одна картинка).

### Сборка

Оба таргета собираются, `xcodebuild test` — 65 тестов зелёные.
