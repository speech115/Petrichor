# Coding Standards

Как мы пишем Swift в этом репозитории. Здесь только то, что **не проверяется
линтером** — договорённости о стиле, которые держатся ревью и памятью команды.
Механические правила живут в `.swiftlint.yml`, и этот документ их не повторяет.

Границы документа:

| Вопрос | Где искать |
|---|---|
| Механика стиля (длина строки, `as!`, скобки…) | `.swiftlint.yml` |
| Архитектура: швы, слои, пути, тесты, ветки | `AGENTS.md` |
| Канон названий домена | `CONTEXT.md` |
| Локализация строк | `docs/LOCALIZATION.md` |

## Именование и структура файлов

- **Один главный тип — один файл.** Имя файла равно имени типа
  (`AVQueuePlayerBackend.swift`, `JSONLPlaybackJournal.swift`). SwiftLint-правило
  `file_name_no_space` это страхует, но не покрывает лишние типы в чужом файле.
- Каталоги отражают слой, а не фичу: `Models/` (значения), `Core/` (безвьюховая
  логика), `Managers/` (сервисы), `Utilities/`, `iOS/` (экраны iPhone, по
  вкладкам: `Home/`, `Player/`, `Playlists/`…). Раскладку «что где лежит» задаёт
  `AGENTS.md`, здесь важно только: новый файл попадает в слой, где живут его
  соседи, а не в новый каталог под одну фичу.
- **Суффикс типа называет его роль.** `Manager` — сервис; `Backend` — реализация
  шва `PlaybackBackend`; `Engine` — интерфейс/координация (`PlaybackEngine`,
  `MetadataEngine`); `Reader` — чтение метаданных; `Store` — неймспейс или
  хранилище (`LibraryPathStore`, `LyricsStore`); `Observation` — узкая проекция
  менеджера; `Delegate` — протокол обратного вызова. Спецроли — `Controller`,
  `Publisher`, `Applier`. Новый тип берёт суффикс своей роли; тип с чужим
  суффиксом — повод спросить, что это на самом деле.

## Типы

- **`final class` по умолчанию.** Ключевое слово `class` без `final` — сигнал
  «здесь ожидается подкласс», поэтому оно встречается редко (например,
  `PlaybackManager`, у которого есть observation-обёртки).
- **Бескейсовый `enum` — неймспейс утилит**, а не структура со статикой:
  `enum LibraryPathStore`, `enum AppearanceApplier`. Он не может быть
  инстанцирован, и это намеренно.
- **Значения — `struct`** (`Track`, `Album`, `Playlist`…). У них нет идентичности
  и поведения; поведение живёт в `Managers`/`Core`.
- **Группировка — `// MARK: - Section`.** Секции внутри типа и перед
  `extension` (см. ниже). Не выдумывайте новых способов деления файла — MARK и
  extension покрывают всё.
- **`extension` для протоколов и функциональных областей.** Протокольная
  реализация (`extension AVQueuePlayerBackend` с transport/now-playing/effects)
  выносится в extension с заголовком `// MARK: - …`, а не смешивается с основной
  логикой типа.
- Частные вспомогательные типы (`private enum AVFoundationEvent: Sendable`)
  объявляются **в начале файла**, до основного типа, а не внутри него.

## Модели (GRDB)

- **Computed `id` стабилен от строки БД, а не от объекта.** `Track.id` — это
  `trackId` с фолбэком на путь для незаписанных треков. Стабильный id нужен для
  diffing `List` и кэшей: перезагрузка того же контента должна давать те же id.
- **Read-only проекции не пишутся через `encode`.** Поля-витрины (`codec`,
  `bitrate` у `Track`) заполняются из таблицы для отображения и не должны
  попадать обратно в базу.
- **`display*`-поля — только в UI-местах.** Они переводят sentinel «Unknown X»;
  сортировка, группировка и запросы идут по raw-полям. Сортировка по
  переведённому тексту ломает порядок незаметно для тестов.

## Concurrency

- **`@MainActor`** на менеджерах, бэкендах и `ObservableObject` — это база.
  Состояние UI и воспроизведения живёт на главном акторе.
- **`Sendable` пишется вместе с обоснованием.** `Sendable` — не украшение, а
  утверждение, которое проверяет компилятор: если тип объявлен `Sendable`, но
  держит незащищённый `var`, ты либо получишь предупреждение (не глуши его),
  либо гонку. В doc-комментарии объясняется, *почему* это безопасно (`Logger`,
  `LogFileManager`): где изменяемое состояние и чем оно защищено.

  ```swift
  // BAD: Sendable-метка без защиты — гонка, которую компилятор лишь подсветит
  final class Cache: Sendable {
      private var entries: [String: Int] = [:]   // незащищённый var
  }

  // GOOD: изменяемое состояние за OSAllocatedUnfairLock, и это объяснено в доке
  final class Logger: Sendable {
      private let minimumLogLevelBox = OSAllocatedUnfairLock(initialState: LogLevel.info)
      // doc: единственное изменяемое состояние — за чекнутой блокировкой
  }
  ```
- **`nonisolated`** — для точек входа, куда приходят вызовы с произвольных потоков
  (AVFoundation KVO/нотификации). Такой метод сам состояния не трогает, а только
  передаёт identity через hop. *Почему:* обратный паттерн — `@objc`-метод, который
  трогает MainActor-состояние, — это гонка, которую не ловят ни линтер, ни
  компилятор: KVO приходит с произвольной очереди молча.

  ```swift
  // BAD: @objc-нотификация трогает MainActor-состояние с произвольного потока
  @objc private func handleItemPlayedToEnd(_ notification: Notification) {
      guard let item = notification.object as? AVPlayerItem else { return }
      self.entries.removeAll()   // гонка: entries — MainActor-состояние
  }

  // GOOD: nonisolated — только identity, состояние переезжает через FIFO-hop
  @objc nonisolated private func handleItemPlayedToEnd(_ notification: Notification) {
      guard let item = notification.object as? AVPlayerItem else { return }
      enqueueAVFoundationEvent(.itemEnded(ObjectIdentifier(item)))
  }
  ```
- **Порядок событий — через main-queue FIFO.** `Task`-хопы не гарантируют
  порядок; когда порядок важен, используется `DispatchQueue.main.async` +
  `MainActor.assumeIsolated` (образец — `enqueueAVFoundationEvent` в
  `AVQueuePlayerBackend`). *Почему:* AVFoundation шлёт события одно за другим
  (`currentItemChanged`, затем `itemEnded`); переупорядоченный Task-хоп может
  применить `itemEnded` раньше смены трека, и индекс очереди разъедется незаметно
  для тестов.

  ```swift
  // BAD: Task-хоп не сохраняет порядок — события AVFoundation могут переупорядочиться
  Task { @MainActor [weak self] in
      self?.handleAVFoundationEvent(event)
  }

  // GOOD: main-queue FIFO сохраняет порядок доставки
  nonisolated private func enqueueAVFoundationEvent(_ event: AVFoundationEvent) {
      DispatchQueue.main.async { [weak self] in
          MainActor.assumeIsolated {
              self?.handleAVFoundationEvent(event)
          }
      }
  }
  ```
- **Тяжёлое/блокирующее — в `Task.detached`**, не на главном акторе (запись на
  диск в `JSONLPlaybackJournal.flush`). Параллельные записи сериализуются своим
  `DispatchQueue`.
- **`[weak self]`** в замыканиях, `weak var` для делегатов. Исключение —
  обоснованное в комментарии.
- Сериализация не через `@MainActor`, а через `OSAllocatedUnfairLock` или
  serial `DispatchQueue` — только когда тип обязан быть `Sendable` и вызываться
  синхронно с любого потока (`Logger.minimumLogLevel`).

## Состояние и публикация

- **`ObservableObject` + `@Published`** (Combine) — способ, которым менеджеры
  отдают состояние. `@Published private(set)` там, где наружу только чтение.
- **Узкие observation-обёртки** вместо того, чтобы подписывать вьюху на весь
  менеджер: `PlaybackAvailabilityObservation`, `PlaybackPresentationObservation`
  проецируют подмножество полей (`currentTrack`, `isPlaying`) и прячут
  остальное. Новая поверхность получает свой узкий тип, а не весь `PlaybackManager`.

## SwiftUI-вьюхи

Вьюхи тестами не покрываются (`AGENTS.md`) — стиль здесь единственный страж,
проверяется ревью, симулятором и устройством.

- **Тело разбивается на `private var` / `private func … -> some View`** и
  `@ViewBuilder` для switch, с секциями `// MARK:`. Гигантский `body` без
  MARK-секций — дефект, как и монолитный файл без деления на области.
- **Владение состоянием по границе:** `@State private` — только локальное
  состояние вьюхи; `@Binding` — то, чем владеет родитель; `@EnvironmentObject` —
  менеджеры, общие для приложения.
- **Нагрузка — через задачу с отменой.** `@State private var …Task` + отмена на
  `.onDisappear`/`.onChange`, тяжёлое — в `Task.detached`, перед применением
  результата — `guard !Task.isCancelled`. Задача без отмены = вьюха обновляется
  после ухода с экрана.
- **Магические числа — `private static let` с именем** (`recentTracksFetchLimit`),
  а не литерал в теле.
- Локализация строк — `String(localized:)`, счётчики — `Text("\(count)")` с
  `.monospacedDigit()` (детали — `docs/LOCALIZATION.md`).

## Обработка ошибок

- Запрещены `try!`, `as!` и force-unwrap — это error-правила линтера, и они не
  отключаются даже точечно.
- Вместо них — `do/catch`, `guard`, условное приведение. Сбой, который можно
  проигнорировать, закрывается `try?`.
- Метод, чей результат вызывающий вправе не использовать, помечается
  `@discardableResult` (`seek(to:)`, `seekForward(_:)`).
- Сбой плеера нормализуется в общий `AudioPlayerError` чистой функцией
  (`AVQueuePlayerBackend.mapPlaybackError`), а не разбросан по месту вызова.

## Логирование

- Только `Logger.info/warning/error/critical` и `Logger.diagnostic`. `print`
  в прод-коде запрещён правилом `no_print_statements`.
- Единственное исключение — `Logger.debugPrint` для SwiftUI Previews и тестов,
  с явным `swiftlint:disable:next no_print_statements` на месте использования.
- `Logger` спроектирован как `Sendable` и вызывается синхронно с любого потока —
  не оборачивайте логирование в `await MainActor`.

## Комментарии и документация

- **Комментарий объясняет «почему», а не «что».** Doc-комментарии на состоянии и
  методах фиксируют контракт конкурентности, неочевидное поведение AVFoundation,
  причину решения (см. заголовочные блоки `AVQueuePlayerBackend`, `Logger`).
  Пересказ кода не нужен.
- **Заголовочный блок файла** — у новых нетривиальных файлов: что это, какие
  решения приняты, какой контракт потоков. Не просто «класс для X».
- **Язык комментария** следует языку соседних комментариев в том же файле.
  Доменные термины — только из канона `CONTEXT.md`, без синонимов, которые он
  помечает как `_Avoid_`.
- Новый код пишется без комментариев «на всякий случай»: комментарий появляется
  там, где он несёт информацию, которой нет в коде.

## Тестируемость

Автотесты пишутся только на швах (`AGENTS.md`), но код, который под них
попадает, пишется тестируемым:

- **Чистые статические функции** для логики, которую хочется проверить без
  окружения (`mapPlaybackError`, `isFileNotFoundError`) — `nonisolated static`,
  без побочных эффектов.
- **Зависимости инжектируются через init с дефолтами**: `JSONLPlaybackJournal(documentsURL:fileManager:)`
  позволяет подсунуть временный `FileManager` в тесте, а прод-код ничего не
  передаёт.
- **Доступ только для тестов — за `#if DEBUG`** (`AVQueuePlayerBackend.preloadedItemCount`),
  а не через ослабление `private` в релизе.

### Как выглядит хороший тест

Тесты проверяют **поведение через публичный интерфейс шва**, а не детали
реализации. Реализация может меняться целиком; тест ломается только когда
поменялось поведение. Тестятся именно швы из `AGENTS.md` — резолв
относительного пути, порядок M3U, метаданные `AVAsset`, сборка библиотеки,
`PlaybackJournal`.

```swift
// GOOD: поведение шва через публичный API, реальный временный FileManager
func testJournalFlushesRelativePath() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let journal = JSONLPlaybackJournal(documentsURL: dir)
    journal.trackPlayed(relativePath: "Music/a.mp3", at: .now)
    try await journal.flush()
    let written = try String(contentsOf: dir.appendingPathComponent("Sync/playback-journal.jsonl"))
    XCTAssertTrue(written.contains("a.mp3"))
}

// BAD: пересказывает реализацию — тест не выживает ни один рефакторинг
func testMapPlaybackErrorHelperUsesSwitch() {
    XCTAssertEqual(AVQueuePlayerBackend.mapPlaybackError(nil), .engineError(/* … */))
}
```

Красные флаги: мок собственных типов (не шва, а внутреннего класса), проверка
приватных методов, тест, который ломается от рефакторинга без смены поведения,
имя теста, описывающее «как», а не «что». Внешние границы (AVFoundation,
`FileManager`) подменяются только на самом шве через init-дефолты — не через
мок внутренних коллабораторов.

- **TDD вертикальными срезами**: один тест → минимальная реализация → зелёный,
  по одному срезу за раз, а не все тесты до всей реализации. Не рефакторить на
  красном.
