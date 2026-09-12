# Ресерч: анимации Apple Music (iOS 26/27) → Petrichor iOS

Дата: 2026-08-13  
Статус: **research** (только выводы, без кода)  
Ориентир: публичные материалы WWDC25 / WWDC26, Apple HIG/SDK, обзоры Music в
iOS 26–27 beta, плюс уже закрытые итерации
`.scratch/library-motion/`, `.scratch/player-defects/`,
`.scratch/playlist-perf/issues/13`.

## Короткий вердикт

У Music в iOS 26–27 две разные «пачки» движения:

1. **Системный Liquid Glass** — tab bar, mini-player accessory, zoom-морф
   презентаций, Lock Screen artwork. Большая часть берётся из API, а не
   пишется вручную.
2. **Музыкальные микроанимации** — дыхание обложки, свайпы, lyrics, equalizer,
   отдача строк. Это поведение приложения, не материала.

Petrichor уже закрыл каркас iOS 26 (minimize tab bar + bottom accessory +
свой Now Playing overlay) и большую часть плеера.

Две анимации, которые чаще всего читаются как «это Music» — и которые
пользователь отдельно отметил 2026-08-13:

1. **Открытие плейлиста/альбома** — zoom hero с обложки в детальную страницу.
2. **Mini-player ↔ Now Playing** — zoom-морф из accessory, не slide снизу.

Первая у нас **никогда не пробовалась** (сейчас обычный push) — чистый
кандидат. Вторая сознательно заменена своим overlay после замера latency;
возвращать только с новой моделью и frame-by-frame планом.

Правило отбора — то же, что в `library-motion`: частота убивает анимацию.

---

## 1. Что делает Apple Music в iOS 26

### 1.1 Liquid Glass и каркас (системное)

Источник: WWDC25 «Meet Liquid Glass», «Build a SwiftUI/UIKit app with the new
design»; Apple Newsroom 2025-06; MacRumors Liquid Glass guide.

| Анимация / поведение | Как устроено | Есть у нас? |
|---|---|---|
| Плавающий tab bar сжимается при скролле | `tabBarMinimizeBehavior(.onScrollDown)` | Да (`ContentView`) |
| Mini-player над tab bar | `tabViewBottomAccessory` | Да |
| Accessory уезжает inline при minimize tab bar; controls сжимаются | Системная анимация `UITabBarController` / SwiftUI | Частично: placement читаем (`tabViewBottomAccessoryPlacement`), layout мини-плеера уже адаптируется |
| Glass на chrome (tab bar, accessory, controls) | Системный материал; опционально `.glassEffect()` / `GlassEffectContainer` | Почти бесплатно от SDK; кастомный glass на контенте не обязателен |
| Zoom-морф sheet/cover / navigation push из источника | `matchedTransitionSource` + `.navigationTransition(.zoom)` | **Нет** ни для плейлистов, ни для Now Playing (плейлисты — обычный push; NP — свой overlay, см. §4) |
| Меню / alerts / popovers «вырастают» из glass-кнопки | Система, если source — bar button / glass control | Бесплатно при системных контролах |

### 1.2 Lock Screen / Now Playing вне приложения

| Поведение | API / суть | Нам? |
|---|---|---|
| Крупный fullscreen artwork на Lock Screen | Системный Now Playing UI iOS 26 | Уже через `MPNowPlayingInfoCenter` (статичная обложка) |
| Анимированная обложка (video / expansive art) | `MPMediaItemAnimatedArtwork`, ключи `1x1` / `3x4` | **Не сейчас**: у локальных файлов почти нет animated assets; без каталога клипов фича пустая |
| Подсветка / «оживление» при wake Always-On | Система + animated artwork | То же ограничение по ассетам |

### 1.3 Классические Music-анимации (живут и в 26)

Не новинки iOS 26, но именно они читаются как «это Music»:

| Место | Поведение |
|---|---|
| Mini → Now Playing | Обложка/карточка зумится в полный экран; dismiss обратно |
| Now Playing artwork | Лёгкий scale «дышит»: play ≈ 1.0, pause ≈ 0.92 |
| Заголовок трека (mini / full) | Горизонтальный свайп = prev / next |
| Мини-плеер | Тонкая линия прогресса; play/pause symbol morph |
| Очередь / Lyrics | Выезжающие панели поверх Now Playing |
| Lyrics | Timed scroll + подсветка активной строки (scale/opacity, не смена веса) |
| Строка трека | Серая press-подсветка; equalizer bars у текущего |
| Фон Now Playing | Цвет из обложки, градиент / blur |
| Scrubber | Утолщение при жесте |

---

## 2. Что добавилось / изменилось в iOS 27

Источники: WWDC26 word-cloud / обзоры 9to5Mac, iDrop, SlashGear (июнь–август
2026). Часть ещё в beta.

| Изменение | Это анимация? | Для Petrichor |
|---|---|---|
| Redesigned **artist page**: фото blend в контент, цвет страницы от изображения, play/info спереди | Layout + scroll/parallax-ощущение, не отдельный «эффект» | Кандидат на полировку `ArtistPage` / `DetailHeader` |
| Refreshed **album pages** | Анонсировано; в ранних beta может не быть | Ждать появления в Music, потом копировать паттерн шапки |
| **Landscape Now Playing** | Orientation layout + transition | Полезно (складные / горизонталь); отдельный layout-тикет |
| Faster Now Playing / streaming start | Perf, не motion | Уже наш фокус (`playlist-perf`) |
| AutoMix лучше | Аудио-переход | Вне скоупа локального плеера |
| System Liquid Glass slider (предпочтения прозрачности) | Системная настройка | Уважать Reduce Transparency / Reduce Motion; не дублировать слайдер |

iOS 27 **не** приносит нового обязательного набора Music-анимаций поверх
каркаса iOS 26. Главный визуальный сдвиг — детальные страницы и landscape NP.

---

## 3. Что уже есть в Petrichor (чтобы не «открыть» заново)

Из кода `iOS/` и закрытых тикетов:

**Каркас iOS 26**
- `tabBarMinimizeBehavior(.onScrollDown)`
- `tabViewBottomAccessory` + адаптация к `tabViewBottomAccessoryPlacement`

**Плеер / motion**
- Единый `NowPlayingPresentationLayer` (mount → один compositingGroup →
  interactive dismiss) — `playlist-perf/13`
- Symbol morph play/pause (`contentTransition(.symbolEffect(.replace))`)
- Equalizer bars в строке
- Lyrics: одна анимация подсветки + отдельный scroll (`player-defects/04`)
- Artwork fade-in при декоде; обложка едет с очередью; mini title crossfade
  (`library-motion` 01–05)
- Scrubber fill / толщина при scrub
- Transport press scale; queue panel spring
- Градиент Now Playing из tint обложки (`two-tab-layout/09`)

**Сознательно отвергнуто (не возвращать без новой модели)**
- Системный `.navigationTransition(.zoom)` для NP — ~0,48 с задержки
  (`playlist-perf/13`, `library-motion` spec)
- Pause-scale обложки `0.86` — конфликт с drag presentation (`bfdee2f`,
  `two-tab-layout/09`)
- Анимации результатов поиска, numericText на тикающих цифрах, stagger полки
  Home (`library-motion` таблица отклонённых)

---

## 4. Две анимации, которые нравятся в Music (разбор)

### 4.1 Открытие плейлиста / альбома — zoom hero

**Что видно в Music**

Тап по обложке в сетке или по строке с миниатюрой: обложка **растёт и
превращается** в шапку детальной страницы. Фон списка подтягивает цвет
обложки (с iOS 26.4 — fullscreen color-matched album/playlist pages). Жест
интерактивный: переход можно схватить и откатить mid-flight. Назад —
тот же морф в обратную сторону.

**Как это называется в SDK**

Не «своя matchedGeometry магия Music», а системный **Zoom Navigation
Transition** (с iOS 18, WWDC24 session 10145):

```swift
@Namespace private var zoomNS

// на карточке / обложке-источнике
.matchedTransitionSource(id: playlist.id, in: zoomNS)

// на destination внутри NavigationStack
.navigationTransition(.zoom(sourceID: playlist.id, in: zoomNS))
```

То же API для push в `NavigationStack` и для sheet/`fullScreenCover`.
Система сама считает geometry path и уважает Reduce Motion.

**Что усиливает ощущение после iOS 26.4**

Не только переход: сама страница плейлиста/альбома стала full-bleed —
крупная обложка плавно вливается в цветной фон трек-листа, Liquid Glass
toolbar/tab bar сидят поверх. Без color-matched destination zoom выглядит
беднее.

**У нас сейчас**

- `PlaylistsTabView` / `HomeTabView`: обычный `NavigationLink(value:)` →
  `PlaylistDetailScreen` — **системный slide push**, без zoom.
- `DetailHeader` уже есть (обложка + Play/Shuffle + лёгкий tint-градиент),
  но не full-bleed color page как в 26.4 и не связан с transition source.

**Вердикт:** это именно та анимация. **Брать.** Zoom на playlist/album/artist
detail — лучший кандидат всей итерации: стандартный API, не ломает плеер,
событие реже строк списка.

### 4.2 Mini-player ↔ Now Playing — zoom-морф accessory

**Что видно в Music**

Мини-плеер (glass accessory над tab bar) при тапе **разворачивается из себя**:
маленькая обложка вырастает в большую, chrome accessory морфится в полный
экран, controls раскладываются. Закрытие — pinch / swipe вниз обратно **в
ту же точку** мини-плеера, а не «уехал вниз в никуда».

В iOS 26 это связано с `tabViewBottomAccessory`: источник перехода —
сама accessory (часто обложка внутри неё) + `.navigationTransition(.zoom)`
на presented Now Playing. Рецепты сообщества (и WWDC25 demo pattern) —
`matchedTransitionSource` на accessory / artwork.

Исторически тот же feel делали через `matchedGeometryEffect` на artwork+title
в одном дереве; для настоящего presentation через tab accessory правильный
путь сегодня — zoom navigation transition, не ручной matched geometry.

**У нас сейчас**

Свой `NowPlayingPresentationLayer`: mount off-screen → spring/ease **slide
вверх одним слоем** → interactive drag dismiss вниз. Обложка **не** зумится
из мини-плеера. Это сознательная замена после:

- попытки `fullScreenCover` + `.navigationTransition(.zoom)` —
  ~0,48 с задержки до первого кадра (`playlist-perf/13`);
- решения не делать пятый заход через `matchedGeometryEffect` внутри overlay
  (`library-motion` spec).

Пользователь 2026-08-09 принял текущий slide («с анимацией плеера тоже всё
отлично»), но 2026-08-13 отдельно отметил, что в Music open/close мини-плеера
нравится больше — то есть gap именно в **морфе из accessory**, не в гладкости
нашего slide.

**Вердикт:** анимация найдена — тот же zoom family, что у плейлистов, но
источник = mini-player accessory. Возврат **дороже**: надо снять свой
presentation layer и заново доказать latency/interactive dismiss на устройстве.
Не путать с pause-scale обложки (тот отдельно отвергнут).

---

## 5. Кандидаты: что можно внедрить

Приоритет = заметность × дешевизна × отсутствие конфликта с текущим
presentation.

### P0 — то, что пользователь уже назвал / дёшево

| # | Кандидат | Почему Music | Как у нас | Риск |
|---|---|---|---|---|
| **Z** | **Zoom open плейлиста/альбома/артиста** | Hero с обложки в detail (§4.1) | Обычный NavigationLink push | Низкий–средний: namespace + id на source/destination; проверить back-swipe |
| A | **Press-подсветка строки трека** | Music подсвечивает серым на touchDown | Тикет `library-motion/06` открыт | Низкий |
| B | **Swipe-up по mini-player → Now Playing** | Канон Music | Тап есть; swipe-up gap в `two-tab-layout/09` | Средний |

### P1 — системный polish / layout destination

| # | Кандидат | Почему Music | Как у нас | Риск |
|---|---|---|---|---|
| **P** | **Full-bleed color page** на playlist/album (как iOS 26.4) | Усиливает zoom destination | `DetailHeader` с лёгким градиентом | Средний по вкусу |
| C | **Glass на chrome** | Music | Audit материалов | Низкий |
| D | **Zoom для вторичных sheets** | WWDC | Track Info обычный sheet | Низкий |
| E | **Свайп по названию = prev/next** | Apple Support | Нет | Средний |

### P2 — дорогой reopen / iOS 27

| # | Кандидат | Почему Music | Как у нас | Риск |
|---|---|---|---|---|
| **H** | **Zoom-морф mini → Now Playing** (§4.2) | Главный feel Music-плеера | Свой slide overlay | **Высокий** — latency history; нужен prototype + замер до замены |
| F | Artist header blend (iOS 27) | Redesign | DetailHeader | Средний |
| G | Landscape Now Playing | iOS 27 | Portrait only | Средний |

### Не брать (или только при ассетах)

| Кандидат | Почему нет |
|---|---|
| `MPMediaItemAnimatedArtwork` / Lock Screen video art | Нет источника анимированных обложек у локальной библиотеки |
| AutoMix / DJ-переходы | Аудио-фича стриминга |
| Pause-scale обложки на NP | Уже снято: ломает unified drag |
| Stagger каруселей Home, анимация поиска, numericText на времени | Частота → шум (`library-motion`) |
| Кастомный glass на каждой карточке/строке | HIG Liquid Glass: материал для chrome, не для контента; GPU-цена |

---

## 6. Рекомендуемый порядок (если делать следующую итерацию)

1. **Z — zoom navigation на playlist/album/(artist) detail** — закрывает
   «как в Music открывается плейлист»; API стандартный.
2. **P — усилить destination** (color-matched / fuller header), чтобы zoom
   приезжал «в Music-страницу», а не в плоский список.
3. **A — press feedback строк**; **B — swipe-up mini-player**.
4. **H — prototype only** для mini→NP zoom: один spike с замером
   time-to-first-frame vs текущего overlay; менять presentation только если
   spike ≤ текущего и interactive dismiss не хуже.
5. Остальное (glass audit, title swipe, landscape) — после.

---

## 7. Источники

- WWDC24: 10145 Enhance your UI animations and transitions (zoom navigation)
- WWDC25: 219 Meet Liquid Glass; 323 Build a SwiftUI app with the new design; 284 UIKit
- Apple Newsroom: Liquid Glass design (2025-06)
- Apple Support: Music player controls (swipe title, Animated Art setting)
- Benjamin Mayo / MacObserver / Pocket-lint: Apple Music fullscreen album/playlist
  pages in iOS 26.4
- 9to5Mac: Lock Screen Music art (iOS 26); Apple Music iOS 27 artist/album
- SDK: `matchedTransitionSource`, `navigationTransition(.zoom)`,
  `tabViewBottomAccessory`, `tabBarMinimizeBehavior`, `.glassEffect()`,
  `MPMediaItemAnimatedArtwork`
- Внутреннее: `.scratch/library-motion/`, `player-defects/`, `playlist-perf/13`,
  `two-tab-layout/09`, `interface/02`

## 8. Границы этого документа

Не меняет канон дизайна. Не открывает implementation-тикеты автоматически —
при старте фазы создать `.scratch/<feature>/issues/` из таблицы §5.
Особенно: **H не реализовывать «заодно» с Z** — разная поверхность риска.
