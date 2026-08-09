# 04 — Изоляция акторов и включение strict concurrency

Status: ready-for-agent
Blocked by: 03

## Проблема

После тикета 03 остаётся ~390 настоящих предупреждений strict concurrency на
iOS-таргете. Ядро проблемы: `LibraryManager`, `PlaylistManager`,
`PlaybackManager` — `ObservableObject`, живущие в UI, но без объявленной
изоляции; компилятор видит захваты non-Sendable `self` в `@Sendable`-замыканиях
(~80 шт.), `sending 'self'` (84), non-Sendable `KeyPath<Track, …>` (70).
Тредность `AVQueuePlayerBackend` держится на ручном `runOnMain` и
комментарии-контракте — ровно то, что Swift 6 проверял бы компилятором.

`DatabaseManager` (`Managers/Database/DatabaseManager.swift:12-23`) — **не**
чистая обёртка пула: `@Published var isScanning`, `@Published var
scanStatusMessage`, `private var lastStatusUpdateTime` — изменяемое состояние
вне `DatabasePool`. Простой `Sendable` не навесить.

## Что сделать

Утверждённые решения (не пересматривать):

1. **`@MainActor` целиком** на `LibraryManager`, `PlaylistManager`,
   `PlaybackManager` — это запись правды (они уже вызываются с main), не
   ограничение. Фоновая работа внутри них остаётся фоновой: тяжёлые куски и
   так уходят в `Task.detached`/GRDB-пул — им понадобится `nonisolated` или
   явная передача, по месту.
2. **Вынос состояния скана из `DatabaseManager`** — по образцу
   `presentationObservation`/`playbackProgressState` в `PlaybackManager`:
   отдельный `@MainActor final class` (имя на усмотрение, например
   `ScanActivityObservation`) с `isScanning`, `scanStatusMessage` и
   throttle-логикой (`lastStatusUpdateTime`, `statusUpdateInterval`).
   Проверить наблюдателей: `grep -rn 'databaseManager.isScanning\|databaseManager.scanStatusMessage\|databaseManager.\$' --include='*.swift' .`
   — и перевести их на новый объект. После выноса `DatabaseManager` перестаёт
   быть `ObservableObject` (если наблюдателей не осталось) и помечается
   `Sendable` — вся оставшаяся изменяемость обязана исчерпываться
   `DatabasePool` (в GRDB он потокобезопасен). Если найдётся ещё изменяемое
   состояние — остановиться и вернуть вопрос владельцу, **не** ставить
   `@unchecked Sendable`.
3. **Запрещено**: `@unchecked Sendable`, `nonisolated(unsafe)`,
   `@preconcurrency import` как способ заглушить предупреждение. Каждое
   предупреждение чинится изоляцией, `Sendable`-типами или пересмотром
   владения.
4. `KeyPath<Track, …>` non-Sendable — чинится обычно заменой хранимых
   KeyPath на замыкания/`KeyPath & Sendable` в сигнатурах сортировок.
5. **Последним коммитом**, когда предупреждений ноль: включить
   `SWIFT_STRICT_CONCURRENCY = complete` в build settings таргета
   `PetrichoriOS` (в `project.pbxproj`, оба конфига Debug/Release) и добавить
   в джобу `ios-test` (`.github/workflows/ci.yml`) шаг-гейт: сборка падает,
   если в логе есть `warning:` (у xcbeautify предупреждения видны; простой
   `grep -c 'warning:'` по сырому логу до xcbeautify тоже годится).
6. **Мак-таргет**: обязан компилироваться со всеми общими изменениями
   (`@MainActor` на менеджерах он получает автоматически). До нуля
   предупреждений его не доводить, strict concurrency на нём не включать,
   гейта нет — Crescendo и Sparkle не наши.

Порядок внутри тикета: сначала вынос скан-состояния (п.2), потом `@MainActor`
(п.1), потом добить остаток, потом включение и гейт (п.5). Промежуточные
коммиты не обязаны иметь ноль strict-предупреждений, но обычная сборка обязана
оставаться с нулём warnings всё время.

## Критерии приёмки

- [ ] `xcodebuild -scheme PetrichoriOS ... build 2>&1 | grep -c warning:` = 0
      при включённом в проекте strict concurrency.
- [ ] `grep -rn '@unchecked Sendable\|nonisolated(unsafe)' --include='*.swift' Managers Core iOS Utilities Models Application`
      — пусто (существующие вхождения, если найдутся, — предмет отдельного
      разговора, новых нет).
- [ ] Обе схемы собираются; `xcodebuild test -scheme PetrichoriOS` зелёный
      целиком (66+ тестов).
- [ ] CI-гейт на предупреждения стоит в `ios-test` и проходит.
- [ ] Смоук на симуляторе: запуск, воспроизведение, открытие Now Playing,
      фон/возврат — без новых runtime-warning'ов о потоках в логе.

## Comments
