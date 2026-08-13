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
свой Now Playing overlay) и большую часть плеера. Имеет смысл добирать
**редкие, читаемые** жесты и системный glass там, где он бесплатен; не
переоткрывать морф обложки и pause-scale без новой модели перехода.

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
| Zoom-морф sheet/cover из источника | `matchedTransitionSource` + `.navigationTransition(.zoom)` | **Нет для Now Playing** — сознательно свой overlay (см. §3) |
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

## 4. Кандидаты: что можно внедрить

Приоритет = заметность × дешевизна × отсутствие конфликта с текущим
presentation.

### P0 — дёшево и часто ощущается

| # | Кандидат | Почему Music | Как у нас | Риск |
|---|---|---|---|---|
| A | **Press-подсветка строки трека** | Music подсвечивает серым на touchDown | Тикет `library-motion/06` открыт; `.buttonStyle(.plain)` глушит систему | Низкий: свой `ButtonStyle` с фоном, без `scaleEffect` |
| B | **Swipe-up по mini-player → Now Playing** | Канон Music / наша спека | Тап есть; swipe-up отмечен как gap в `two-tab-layout/09` | Средний: не сломать drag dismiss NP и hit-testing accessory |

### P1 — системный iOS 26 polish

| # | Кандидат | Почему Music | Как у нас | Риск |
|---|---|---|---|---|
| C | **Glass на chrome, не на контенте** | Music держит glass на tab/accessory/controls | Проверить, что мини-плеер и sheets не перекрыты кастомным `.ultraThinMaterial` там, где система уже даёт glass | Низкий, если не класть glass на списки/обложки |
| D | **Zoom-морф для вторичных sheets** (Track Info, меню из toolbar) | WWDC: sheet растёт из кнопки | Track Info сейчас обычный sheet | Низкий; не трогать Now Playing |
| E | **Свайп по названию = prev/next** (mini + NP) | Документировано в Apple Support | Нет | Средний: конфликт со свайпом dismiss / queue |

### P2 — iOS 27 / редкие события

| # | Кандидат | Почему Music | Как у нас | Риск |
|---|---|---|---|---|
| F | **Artist header blend** (цвет страницы от фото, мягкий переход в список) | iOS 27 artist redesign | `DetailHeader` / `ArtistPage` уже есть; нужен visual polish | Средний по вкусу, низкий по perf |
| G | **Landscape Now Playing** | iOS 27 | Только portrait layout | Средний: второй layout + safe areas |
| H | **Большой matched-geometry морф mini→NP** | Самое заметное отличие от Music | Сознательно свой overlay | **Высокий** — пятый заход; только если текущий transition снова станет проблемой и есть frame-by-frame план |

### Не брать (или только при ассетах)

| Кандидат | Почему нет |
|---|---|
| `MPMediaItemAnimatedArtwork` / Lock Screen video art | Нет источника анимированных обложек у локальной библиотеки |
| AutoMix / DJ-переходы | Аудио-фича стриминга |
| Pause-scale обложки на NP | Уже снято: ломает unified drag |
| Stagger каруселей Home, анимация поиска, numericText на времени | Частота → шум (`library-motion`) |
| Кастомный glass на каждой карточке/строке | HIG Liquid Glass: материал для chrome, не для контента; GPU-цена |

---

## 5. Рекомендуемый порядок (если делать следующую итерацию)

1. **A — press feedback строк** (закрыть `library-motion/06` после проверки пальцем).
2. **B — swipe-up mini-player**, не ломая текущий `NowPlayingPresentationLayer`.
3. **C/D — audit glass**: убрать лишние материалы, дать системе zoom на мелких sheets.
4. **E — title swipe prev/next**, если жесты не конфликтуют с dismiss.
5. **F/G — iOS 27 layout polish** отдельной фазой после стабилизации motion.

Морф обложки (H) и animated Lock Screen — вне очереди.

---

## 6. Источники

- Apple Newsroom: Liquid Glass design (2025-06)
- WWDC25: 219 Meet Liquid Glass; 323 Build a SwiftUI app with the new design; 284 UIKit
- Apple Support: Music player controls (swipe title, Animated Art setting)
- 9to5Mac: Lock Screen Music art (iOS 26); Apple Music iOS 27 artist/album
- SDK: `tabViewBottomAccessory`, `tabBarMinimizeBehavior`, `matchedTransitionSource`,
  `navigationTransition(.zoom)`, `MPMediaItemAnimatedArtwork`, `.glassEffect()`
- Внутреннее: `.scratch/library-motion/`, `player-defects/`, `playlist-perf/13`,
  `two-tab-layout/09`, `interface/02`

## 7. Границы этого документа

Не меняет канон дизайна. Не открывает implementation-тикеты автоматически —
при старте фазы создать `.scratch/<feature>/issues/` из таблицы §4.
