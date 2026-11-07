# Машины состояний Petrichor

Живой документ. Описывает явные и неявные машины состояний общих слоёв и
iOS-таргета: состояния, инварианты, таблицы переходов и найденные
недопустимые состояния, которых код может достичь. Каждое исправление
обновляет раздел своей машины и строку в «Реестре дефектов» внизу.

Обозначения: **I-n** — инвариант, **SM-n** — машина, **D-n** — дефект.
Ссылки вида `файл:строка` даны на коммит `c5ed6ea` (main, 2026-11-06).

Вне охвата: `CrescendoPlaybackBackend` (macOS), макошные `Views/`, SwiftUI-
состояния анимаций (зум плеера, drag), проверяемые только на устройстве.

---

## SM-1. Транспорт iOS-бэкенда (`AVQueuePlayerBackend`)

Явное состояние — `AudioPlayerState`, выводится из
`AVPlayer.timeControlStatus` и пустоты очереди (`mapState`). Скрытые
переменные, которые на деле образуют состояние:

| Переменная | Смысл |
|---|---|
| `entries`, `currentIndex` | очередь движка и указатель текущей записи |
| `player.items()` | окно: текущий item + `lookaheadItemCount` (1) следующих |
| `wantsPlayback` | приложение просило играть (для конца прерывания) |
| `previousState` | последнее отданное делегату состояние (дедуп) |
| `itemEntryMap` / `itemObjectMap` / `failedItemKeys` | атрибуция событий item → entry |
| `positionBeforeReset` | позиция на момент сброса media services |

Состояния: **stopped** (`entries` пусты) · **paused** · **playing**
(включая `.waitingToPlayAtSpecifiedRate`).

Инварианты:

- **I-1.1** `entries.isEmpty ⇔ state == .stopped`.
- **I-1.2** `entries.isEmpty || entries.indices.contains(currentIndex)`.
- **I-1.3** `player.currentItem`, если есть, принадлежит `entries[currentIndex]`
  (`itemEntryMap[currentItem] == entries[currentIndex].entryId`).
- **I-1.4** `player.items().dropFirst()` — это ровно
  `entries[currentIndex+1 ..< currentIndex+1+lookahead]`.
- **I-1.5** `wantsPlayback == false`, пока пользователь не просил играть
  после последней паузы.
- **I-1.6** Все события AVFoundation обрабатываются на main в порядке FIFO
  (`enqueueAVFoundationEvent`), события устаревшего item отбрасываются.

| Из | Событие | В | Побочные эффекты |
|---|---|---|---|
| stopped | `setQueue(startPaused: false)` | playing | `activate()` сессии; при отказе — paused |
| stopped | `setQueue(startPaused: true)` | paused | `backendStateChanged(.paused)` синхронно |
| paused | `resume()` | playing | пустой плеер при непустой очереди → пересборка окна |
| playing | `pause()` / начало прерывания / наушники выдернуты | paused | `wantsPlayback = false` |
| playing | `didPlayToEnd`, есть преемник | playing | finish(eof) → `currentIndex+1` → `advanceToNextItem` → `play()` |
| playing | `didPlayToEnd`, преемника нет | paused | `seek(0)`, `wantsPlayback = false` |
| любое | item failed (не текущий) | то же | запись удаляется, `didSkipQueueEntry` |
| playing | текущий item failed | playing/paused | преемник ставится, играет только при `wantsPlayback` |
| любое | media services reset | то же | новый `AVQueuePlayer`, окно пересобрано, seek к позиции |
| любое | `clearQueue()` / `stop()` | stopped | `wantsPlayback = false` |

Достижимые нарушения: **D-6** (I-1.3 после удаления текущей записи),
**D-7** (I-1.5 на границе трека).

## SM-2. Очередь приложения и её зеркало в движке

Самая нагруженная неявная машина. Состояние распределено между
`PlaylistManager` (`currentQueue`, `currentQueueIndex`, `repeatMode`,
`isShuffleEnabled`) и `PlaybackManager` (`mirror`, `currentEntryId`,
`injectedNext`, `unmirroredTracks`, `currentTrack`, `currentFullTrack`).

Режимы:

- **Idle** — `currentTrack == nil`, `mirror` пуст, движок stopped.
- **Restored-unmirrored** — очередь восстановлена, `currentTrack` есть,
  `mirror` пуст, движок stopped (после SM-3 до первого Play).
- **Mirrored** — `mirror` не пуст, движок играет запись из него.
- **Off-queue** — `mirror` пуст, одна запись в `unmirroredTracks`
  (трек не найден в `currentQueue`).

Инварианты:

- **I-2.1** В Mirrored `mirror.count == currentQueue.count` и
  `mirror[i].track.id == currentQueue[i].id`.
- **I-2.2** В Mirrored `currentQueueIndex == queuePosition(ofEntry: currentEntryId)`.
  Курсор очереди указывает на то, что реально играет.
- **I-2.3** Множество записей движка = `mirror` ∪ `injectedNext` ∪ (off-queue
  запись); других записей движок не держит.
- **I-2.4** `injectedNext != nil` только когда следующий по `repeatMode`
  отличается от `currentQueueIndex + 1` (repeat-one; repeat-all на последней).
- **I-2.5** `currentEntryId` никогда не удаляется из движка вызовом очереди
  (`queueDidRemove`, `playNext`-дедуп, `removeFromQueue` это охраняют).
- **I-2.6** `currentQueueIndex ∈ [-1, currentQueue.count)`, −1 только при
  пустой очереди.

| Из | Событие | В | Что меняется |
|---|---|---|---|
| Idle/любое | тап по строке (`play(_:source:)`) | Mirrored | `replaceCurrentQueue` + `startQueue(at:)` → новый `mirror`, новые entryId |
| Mirrored | тап по той же плейлистной странице | Mirrored | `jumpToQueueEntry` без пересборки |
| Restored-unmirrored | Play | Mirrored/Off-queue | `startPlayback` ищет трек по URL в `currentQueue` |
| Mirrored | движок перешёл сам | Mirrored | `handleEngineAdvance` → `advanceQueueIndex` |
| Mirrored | запуск `injectedNext` | Mirrored | `absorbInjectedEntry` заменяет запись `standsInFor` |
| Mirrored | playNext / add / remove / move | Mirrored | правка `currentQueue`, затем `queueDid*` по entryId |
| Mirrored | shuffle on | Mirrored | движок тасует хвост, порядок читается обратно |
| Restored-unmirrored | shuffle on | Restored-unmirrored | тасовка на стороне приложения |
| Mirrored | запись не декодируется | Mirrored | `dropSkippedEntry` из `mirror` и `currentQueue` |
| любое | `clearQueue` / `stop` | Idle | всё обнуляется |

Достижимые нарушения: **D-1** (I-2.2), **D-2** (I-2.1 и I-2.2), **D-6**
(I-2.5 через гонку `clearInjectedNext`).

## SM-3. Восстановление воспроизведения при запуске

`AppCoordinator` + `PlaybackManager`. Неявные флаги: `isRestoringPlayback`,
`libraryObserver`, `restoredUITrack`, `pendingPlayOnRestore`,
`pendingRestoreResume`.

Состояния:

1. **NoState** — сохранения нет или библиотека пуста.
2. **TileShown** — `restoreUIStateImmediately`: `currentTrack` = временный
   трек `/restored` без `trackId`, `restoredUITrack` тот же.
3. **WaitingForLibrary** — счётчики ещё не загружены, ждём `LibraryDidLoad`.
4. **Loading** — `loadRestoration` в detached-задаче.
5. **Applied** — очередь восстановлена, `prepareTrackForRestoration`
   загружает `FullTrack`, затем режим SM-2 Restored-unmirrored.
6. **Discarded** — сохранение очищено, плитка снята.

Защёлки: **PlayLatched** (`pendingPlayOnRestore`, `isPlaying = true` при
нажатии Play в TileShown/WaitingForLibrary/Loading) и **ResumePending**
(`pendingRestoreResume`: старт с паузы → seek → resume на переходе в
`.paused`).

Инварианты:

- **I-3.1** Временная плитка (`currentTrack.trackId == nil`, URL `/restored`)
  существует только пока восстановление не завершено.
- **I-3.2** `pendingPlayOnRestore ⇒` восстановление ещё в пути; любой исход
  снимает защёлку.
- **I-3.3** Восстановление не перетирает воспроизведение, которое
  пользователь начал сам после запуска.
- **I-3.4** Пока `currentTrack` — временная плитка, сохранение не пишется
  (иначе перетрётся реальный трек).

| Из | Событие | В |
|---|---|---|
| — | init, есть папки и UI-состояние | TileShown |
| TileShown | +0.2 с, счётчики 0 | WaitingForLibrary |
| TileShown | +0.2 с, счётчики есть | Loading |
| WaitingForLibrary | `LibraryDidLoad` | Loading / Discarded |
| Loading | decode fail, старше 7 дней, < 50 % очереди | Discarded |
| Loading | трек нечитаем | Discarded |
| Loading | текущий трек найден | Applied |
| Loading | текущий трек не найден в очереди | **плитка остаётся** (D-3) |
| TileShown…Loading | Play | + PlayLatched |
| Applied | Play | SM-2 Mirrored (через ResumePending, если позиция > 0) |

Достижимые нарушения: **D-2** (I-3.3), **D-3** (I-3.1, I-3.2).

## SM-4. Аудиосессия и прерывания (`AudioSessionController`)

Состояния: **Inactive** → **Active** (после первого `activate()`) ⇄
**Interrupted(wasPlaying)**; плюс **ResetPending** (дебаунс 0.5 с после
`mediaServicesWereReset`, приходит дважды на iOS 27).

- **I-4.1** Конец прерывания возобновляет звук только если перед началом
  `wantsPlayback == true` и система прислала `.shouldResume`.
- **I-4.2** Выдернутые наушники во время звонка сбрасывают `wasPlaying`.
- **I-4.3** Один reset → одна пересборка плеера.

| Из | Событие | В |
|---|---|---|
| Inactive | первый старт воспроизведения | Active (категория `.playback`) |
| Active | interruption began | Interrupted(wantsPlayback) + pause |
| Interrupted | ended + shouldResume + wasPlaying | Active + resume |
| Interrupted | ended иначе | Active, на паузе |
| любое | route `oldDeviceUnavailable` на динамик | pause, wasPlaying = false |
| любое | media services reset (×N за 0.5 с) | ResetPending → пересборка |

Нарушений не найдено.

## SM-5. Сверка библиотеки и скан (iOS)

`LibraryReconciliation` + `DMFolders.addFoldersAsync` + `ScanActivityObservation`.
Флаги-ворота: `isReconcilingLibrary`, `isScanningLibraryRoot`; флаги
онбординга: `isInitialOnboardingScan`, `hasReachedInitialScanThreshold`.

Состояния ворот сверки: **Idle** → **Reconciling** (проверка изменений) →
**Scanning** → **ImportingM3U** → Idle.

- **I-5.1** Одновременно идёт не больше одного скана корня.
- **I-5.2** Запрос на скан, пришедший во время скана, не теряется: файлы,
  появившиеся после начала обхода, попадают в базу без ожидания следующего
  возврата в приложение.
- **I-5.3** Любой выход из скана (в том числе throw) снимает `isScanning` и
  шлёт `.initialScanCompleted`, если слал `.initialScanStarted`.

| Из | Событие | В |
|---|---|---|
| Idle | запуск / возврат в foreground | Reconciling |
| Reconciling | папок нет или файлы изменились | Scanning |
| Reconciling | без изменений | ImportingM3U |
| Scanning | готово / throw | ImportingM3U / Idle |
| Reconciling, Scanning | ещё один foreground | **отброшено** (D-4) |
| Scanning | «Rescan» / импорт файлов из пикера | **отброшено** (D-4) |

Достижимое нарушение: **D-4** (I-5.2).

## SM-6. Синхронизация Spotlight (`SpotlightIndexer`, actor)

Флаги: `isSyncing`, `resetPending`, `resetGeneration`; снимки на диске —
курсор полного прохода.

- **I-6.1** Пишет снимок только проход, начатый после последнего reset
  (`generation == resetGeneration`).
- **I-6.2** Reset, пришедший во время прохода, приводит к ещё одному
  проходу после текущего.
- **I-6.3** Изменение базы, пришедшее во время прохода, тоже приводит к
  повторному проходу (иначе индекс отстаёт до следующего события).

| Из | Событие | В |
|---|---|---|
| Idle | `scheduleSync` | Syncing |
| Syncing | `scheduleSync` | **отброшено** (D-4) |
| Syncing | `resetIndex` | Syncing + resetPending, generation+1 |
| Syncing | проход закончен, resetPending | Syncing (повтор) |
| Idle | `resetIndex` | wipe → Syncing |

Достижимое нарушение: **D-4** (I-6.3).

## SM-7. Журнал прослушиваний

Писатель (`JSONLPlaybackJournal`): **Idle** → **Flushing** (`flushTask`) →
Idle; при ошибке батч возвращается в начало `pending`.

- **I-7.1** Порядок событий в файле совпадает с порядком записи.
- **I-7.2** Частичная дозапись откатывается (`truncate`), повтор не дублирует.

Применитель (`PlaybackJournalApplier`): курсор `applied_through` в одной
транзакции с правками треков.

- **I-7.3** Каждое событие пира применяется ровно один раз.
- **I-7.4** Счётчик прослушиваний — сумма локальных и пришедших событий,
  ни одно не теряется.

Достижимые нарушения: **D-5** (I-7.4, гонка read-modify-write), **D-8**
(I-7.3 для событий в ту же секунду и для событий, не нашедших трек).

## SM-8. Открытие базы (`AppLaunch`)

**Opening** → **Running** | **Failed(error)**; из Failed: Try Again →
Opening; Reset → (удалить файлы, `resetPending = true`) → Opening; первый
успешный Opening после Reset вызывает `didReset` (сброс Spotlight).

- **I-8.1** Менеджеры строятся только на открытой базе.
- **I-8.2** `didReset` вызывается ровно один раз на reset, даже если база
  открылась лишь на повторной попытке.

Нарушений не найдено (покрыто `DatabaseOpenFailureTests`).

## SM-9. Фоновые миграции (`DMBackgroundMigration`)

На каждую миграцию: **Pending(progress)** → **Running** → **Completed**;
сбой оставляет Pending с сохранённым прогрессом. Пустая база помечает всё
Completed. Нарушений, достижимых на текущих базах, не найдено: все
миграции уже прошли на устройствах; пагинация по `OFFSET` теоретически
пропускает строки при одновременном скане.

## SM-10. Сохранение при уходе в фон (`PetrichorApp`)

`playbackSaveTask` + `needsPlaybackSave` + `backgroundSaveID`: **Idle** →
**Saving** (повторяется, пока во время записи пришёл новый запрос) → Idle,
background task закрывается ровно один раз. Нарушений не найдено.

## SM-11. Загрузка информации об артистах (`ArtistBioManager`)

**Idle** → **Fetching** (`fetchTask`) → Idle; ворота `minimumRunInterval`;
предохранитель «10 сетевых ошибок подряд». Нарушений с заметным эффектом не
найдено.

---

## Реестр дефектов

Приоритет — по влиянию на пользователя и вероятности. Статус: найден /
фикс и тест в PR / исправлен (влит в main).

| ID | Приоритет | Машина | Статус |
|---|---|---|---|
| D-1 | P1 | SM-2 | фикс и тест в #96 (`QueueCursorTests`) |
| D-2 | P2 | SM-2, SM-3 | фикс и тест в #96 (`RestorationRaceTests`) |
| D-3 | P2 | SM-3 | фикс и тест в #96 (`RestorationRaceTests`) |
| D-4 | P2 | SM-5, SM-6 | фикс и тесты в #97 (`ScanRequestTests`, `CoalescingRunnerTests`) |
| D-5 | P3 | SM-7 | фикс и тесты в #98 (`PlayCountSyncTests`) |
| D-6 | P3 | SM-1, SM-2 | фикс и тест в #99 (`QueueBackendTests`) |
| D-7 | P3 | SM-1 | фикс и тест в #99 (`QueueBackendTests`) |
| D-8 | P3 | SM-7 | фикс и тесты в #98 (`PlaybackJournalTests`) |

### D-1. Курсор очереди не совпадает с играющим треком

Нарушает I-2.2. `startQueue(at:)` (`Managers/PlaybackQueueMirror.swift:188`)
двигает `currentQueueIndex`, только если `firstPlayableIndex` сместил
старт; при старте из `startPlayback` позиция найдена по URL
(`Managers/PlaybackManager.swift:446`) и курсор остаётся прежним. Курсор
расходится с позицией в двух местах:

- тасовка без зеркала (`Managers/Playlist/PMQueue.swift:165`) ставит
  `currentQueueIndex = 0`, а восстановленный трек оказывается где угодно;
- восстановление берёт `state.currentQueueIndex` исходной очереди, а
  пропавшие треки перед текущим сдвигают позиции (когда метка позиции не
  совпала).

Сценарий: запуск с восстановленным треком на паузе → Shuffle → Play →
Next. Играет `currentQueue[1]` вместо следующего за текущим, «Далее» в
очереди показывает не тот хвост; repeat-lookahead строится от неверного
курсора.

### D-2. Восстановление перетирает трек, который пользователь уже включил

Нарушает I-3.3 и I-2.1. `apply(_:)` (`Application/AppCoordinator.swift:427`)
и асинхронный хвост `prepareTrackForRestoration`
(`Managers/PlaybackManager.swift:181`) не проверяют, началось ли
воспроизведение после запуска; ветка `.discard` вызывает
`clearAllSavedState`, который обнуляет `currentTrack`. Окно: от появления
интерфейса до конца `loadRestoration` (ожидание `LibraryDidLoad` после
COUNT-запросов холодной базы + выборка очереди).

Сценарий: холодный запуск → в первые секунды тап по песне на Главной.
Звучит выбранная песня, а плеер показывает восстановленный трек на паузе,
`currentQueue` — восстановленная очередь, `mirror` — очередь тапа. Play
запускает восстановленный трек поверх; правки очереди адресуют не те
записи движка.

### D-3. Временная плитка остаётся навсегда, Play «играет» тишину

Нарушает I-3.1 и I-3.2. Если восстановленная очередь не содержит текущего
трека (`restoration.currentTrack == nil`), `apply` только снимает защёлку
(`Application/AppCoordinator.swift:466`), но временный трек `/restored`
остаётся `currentTrack`. Нажатие Play попадает в ветку
`pendingPlayOnRestore = true; isPlaying = true`
(`Managers/PlaybackManager.swift:246`), и снять её уже некому.

Сценарий: последний трек очереди не открылся (битый файл) → он выпал из
очереди, но остался текущим → уход в фон сохранил его → перезапуск. Плитка
показывает трек, Play переключает кнопку на паузу без звука.

### D-4. Ворота «одна задача за раз» теряют запросы

Нарушает I-5.2 и I-6.3. `scanLibraryRoot()`, `reconcileLibrary()`
(`iOS/LibraryReconciliation.swift:55`, `:103`) и
`SpotlightIndexer.syncAfterReconciliation` (`iOS/SpotlightIndexer.swift:191`)
при занятых воротах просто выходят. Запрос, пришедший во время работы,
пропадает, хотя текущий проход мог уже прочитать старое состояние.

Сценарии: импорт файлов из пикера во время сканирования при запуске —
`importMusicFiles` копирует файлы и возвращает успех, а скан пропущен,
треки появятся только после следующего возврата в приложение. Долгая
первая индексация Spotlight: `scheduleSync` после конца скана отброшен,
новые треки не ищутся до следующего изменения базы.

### D-5. Потеря прослушивания при одновременной записи счётчика

Нарушает I-7.4. `incrementPlayCount` (`Managers/Playlist/PMTrackUpdate.swift:130`)
читает `play_count`, затем отдельной записью ставит `+1`. Между чтением и
записью может пройти транзакция применителя журнала (возврат в foreground
совпал с концом трека в фоне): прослушивание с Mac теряется.

### D-6. Удаление текущей записи движка оставляет «сироту»

Нарушает I-1.3 и I-2.5. `removeQueueEntry(at: currentIndex)`
(`iOS/AVQueuePlayerBackend.swift:215`) удаляет запись, но не item из плеера;
`refillUpcomingItems` заменяет преемника. Доигравший item не находится в
`entries`, `handleItemEnded` выходит, плеер встаёт на паузу. Достижимо
только гонкой: смена repeat-режима (`receive(on: main)`) между концом трека и
событием смены `currentItem` вызывает `clearInjectedNext` для уже
заигравшей вставленной записи.

### D-7. Пауза на стыке треков отменяется

Нарушает I-1.5. `handleItemEnded` (`iOS/AVQueuePlayerBackend.swift:457`)
вызывает `player.play()` напрямую, без `startPlayer()`. Если пауза
нажата, пока событие конца трека ждёт в main-очереди, следующий трек всё
равно заиграет, а сессия не переактивируется.

### D-8. Курсор журнала пропускает события

Нарушает I-7.3. Метки времени пишутся с точностью до секунды
(`Core/Playback/PlaybackJournal.swift:92`), курсор сравнивается строго `>`:
событие в ту же секунду, что и последнее применённое, но приехавшее
следующей синхронизацией, теряется. Событие, не нашедшее трек (Mac
проиграл песню, которой на телефоне ещё нет), остаётся позади курсора и
не применяется никогда.
