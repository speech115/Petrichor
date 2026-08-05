# Musify: фундамент — сборка, база, файлы, воспроизведение

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Довести iOS-таргет до состояния, когда Musify запускается на iPhone, сканирует музыку из своей папки `Documents` и играет её с бесшовными переходами, фоном и блокировочным экраном.

**Architecture:** Общее ядро Petrichor (Models, Core, Managers, Utilities) компилируется в оба таргета. Платформенные различия живут в четырёх швах: воспроизведение (`PlaybackBackend`), метаданные (`MetadataEngine`), изображения (`PlatformImage`) и пути к файлам (`LibraryPathStore`, вводится этим планом). iOS-адаптеры лежат в `iOS/`, макошные представления в iOS-таргет не входят.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation (AVQueuePlayer), MediaPlayer, GRDB 7.11, Swift Testing, Xcode 26.6.

## Global Constraints

- Минимальная версия — **iOS 26.0**. Обратную совместимость не поддерживаем.
- Bundle identifier iOS-таргета — **`com.sereja.musify`**. Мак-таргет остаётся `org.Petrichor` и в этом плане не меняется вообще.
- Имя iOS-таргета, схемы и приложения — **Musify**.
- Новые `#if os(...)` допустимы **только** в четырёх швах и в `Views/`. Любое другое платформенное ветвление — повод завести новый шов, а не разветвление по месту.
- Эквалайзер на iOS не поддерживается: методы EQ в бэкенде — пустые реализации.
- Бесшовные переходы между треками обязательны.
- Пути к файлам в базе хранятся **относительно `Documents/`**; абсолютные пути в базу не пишутся никогда.
- Работа идёт в ветке `ios-port` репозитория `~/Projects/apps/musify`.
- Все команды `xcodebuild` выполняются из корня репозитория.
- Симулятор для тестов: `iPhone 17 Pro Max`.

---

## File Structure

**Создаются:**

| Файл | Ответственность |
|---|---|
| `Utilities/LibraryPathStore.swift` | Шов путей: преобразование между хранимой строкой и `URL` |
| `iOS/AVQueuePlayerBackend.swift` | iOS-адаптер `PlaybackBackend` на AVQueuePlayer |
| `iOS/AudioSessionController.swift` | Категория аудиосессии, прерывания, смена маршрута |
| `iOS/NowPlayingPublisher.swift` | Публикация в `MPNowPlayingInfoCenter` |
| `iOS/TrackListDebugView.swift` | Временный экран проверки: список треков, тап играет |
| `Tests/MusifyTests/LibraryPathStoreTests.swift` | Тесты шва путей |
| `Tests/MusifyTests/TrackPersistenceTests.swift` | Тесты round-trip моделей |
| `Tests/MusifyTests/FolderScanTests.swift` | Тесты сканирования папки |
| `Tests/MusifyTests/MetadataMappingTests.swift` | Тесты маппинга метаданных |
| `Tests/MusifyTests/QueueBackendTests.swift` | Тесты очереди бэкенда |

**Изменяются:**

| Файл | Что меняется |
|---|---|
| `Petrichor.xcodeproj/project.pbxproj` | Переименование таргета, bundle id, привязка GRDB, тестовый таргет |
| `Configuration/Info-iOS.plist` | Доступ к папке из Finder и «Файлов» |
| `Models/Core/Track.swift` | Кодирование пути через `LibraryPathStore` |
| `Models/Core/Folder.swift` | То же + отказ от bookmarks на iOS |
| `Managers/Database/DatabaseManager.swift` | Имя файла базы от bundle id |
| `Managers/Library/LMFolders.swift` | `scanLibraryRoot()`: регистрирует `Documents` через существующий конвейер `addFoldersAsync`/`scanFoldersForTracks`, без bookmarks |
| `Core/Playback/PlaybackEngine.swift` | Выбор нового бэкенда на iOS |
| `iOS/PetrichorApp.swift` | Переименование в `MusifyApp`, стартовый экран |

**Удаляется:** `iOS/AVAudioPlaybackBackend.swift` — заменяется на AVQueuePlayer-версию.

---

### Task 1: Переименовать таргет в Musify и починить сборку

Сейчас сборка падает на `unable to resolve module dependency: 'GRDB'` — пакет привязан только к мак-таргету.

**Files:**
- Modify: `Petrichor.xcodeproj/project.pbxproj`
- Modify: `Configuration/Info-iOS.plist`

**Interfaces:**
- Consumes: ничего
- Produces: схема `Musify`, собираемая командой `xcodebuild -scheme Musify -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build`

- [ ] **Step 1: Убедиться, что сборка сейчас падает**

```bash
xcodebuild -project Petrichor.xcodeproj -target PetrichoriOS -sdk iphonesimulator build 2>&1 | grep -E "error:|BUILD"
```

Expected: `error: unable to resolve module dependency: 'GRDB'` и `** BUILD FAILED **`

- [ ] **Step 2: Переименовать таргет и схему**

В Xcode: выбрать таргет `PetrichoriOS` → Identity and Type → Name: `Musify`. Затем Product → Scheme → Manage Schemes → переименовать схему в `Musify`, поставить галочку Shared.

- [ ] **Step 3: Задать bundle identifier и версию платформы**

В настройках таргета `Musify`:
- `PRODUCT_BUNDLE_IDENTIFIER` = `com.sereja.musify`
- `IPHONEOS_DEPLOYMENT_TARGET` = `26.0`
- `PRODUCT_NAME` = `Musify`
- `INFOPLIST_FILE` = `Configuration/Info-iOS.plist`

- [ ] **Step 4: Привязать GRDB к таргету**

Target `Musify` → General → Frameworks, Libraries, and Embedded Content → `+` → выбрать `GRDB` из пакета `GRDB.swift`. Crescendo и Sparkle **не добавлять** — они macOS-only.

- [ ] **Step 5: Обновить Info-iOS.plist**

Заменить значения:

```xml
<key>CFBundleDisplayName</key>
<string>Musify</string>
<key>CFBundleName</key>
<string>Musify</string>
```

- [ ] **Step 6: Собрать**

```bash
xcodebuild -scheme Musify -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build 2>&1 | grep -E "error:|BUILD"
```

Expected: `** BUILD SUCCEEDED **`. Если всплывают ошибки компиляции в файлах `Views/` — значит они ошибочно попали в таргет: убрать их из Target Membership (в iOS-таргет входят только `Models`, `Core`, `Managers`, `Utilities`, `Application`, `iOS`).

- [ ] **Step 7: Коммит**

```bash
git add Petrichor.xcodeproj Configuration/Info-iOS.plist
git commit -m "build: rename iOS target to Musify and link GRDB"
```

---

### Task 2: Завести тестовый таргет

В проекте нет ни одного теста. Без таргета следующие задачи не смогут работать по TDD.

**Files:**
- Modify: `Petrichor.xcodeproj/project.pbxproj`
- Create: `Tests/MusifyTests/SmokeTests.swift`

**Interfaces:**
- Consumes: схема `Musify` из Task 1
- Produces: таргет `MusifyTests`, запускаемый через `xcodebuild test -scheme Musify -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'`

- [ ] **Step 1: Создать таргет**

В Xcode: File → New → Target → Unit Testing Bundle. Product Name: `MusifyTests`, Target to be Tested: `Musify`, Testing System: **Swift Testing**. Путь к файлам изменить на `Tests/MusifyTests`.

- [ ] **Step 2: Написать проверочный тест**

Создать `Tests/MusifyTests/SmokeTests.swift`:

```swift
import Testing
@testable import Musify

@Test func testTargetIsWiredUp() {
    #expect(Bundle.main.bundleIdentifier != nil)
}
```

- [ ] **Step 3: Прогнать тесты**

```bash
xcodebuild test -scheme Musify -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' 2>&1 | grep -E "Test Suite|passed|failed|error:"
```

Expected: тест проходит.

- [ ] **Step 4: Коммит**

```bash
git add Petrichor.xcodeproj Tests
git commit -m "test: add MusifyTests target"
```

---

### Task 3: Шов путей — LibraryPathStore

Четвёртый шов. На macOS хранится абсолютный путь (как сейчас), на iOS — путь относительно `Documents`, потому что UUID контейнера не стабилен между установками.

**Files:**
- Create: `Utilities/LibraryPathStore.swift`
- Test: `Tests/MusifyTests/LibraryPathStoreTests.swift`

**Interfaces:**
- Consumes: ничего
- Produces:
  - `enum LibraryPathStore`
  - `static func storedPath(for url: URL) -> String`
  - `static func url(fromStored path: String) -> URL`
  - `static var libraryRoot: URL` — на iOS `Documents`, на macOS корень файловой системы

- [ ] **Step 1: Написать падающие тесты**

Создать `Tests/MusifyTests/LibraryPathStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import Musify

@Test func storedPathIsRelativeToLibraryRoot() {
    let url = LibraryPathStore.libraryRoot
        .appendingPathComponent("Моя музыка/Spotify/0239 - Jeune Ras.mp3")

    #expect(LibraryPathStore.storedPath(for: url) == "Моя музыка/Spotify/0239 - Jeune Ras.mp3")
}

@Test func storedPathRoundTripsBackToTheSameURL() {
    let url = LibraryPathStore.libraryRoot
        .appendingPathComponent("Моя музыка/ВКонтакте/track.mp3")

    let restored = LibraryPathStore.url(fromStored: LibraryPathStore.storedPath(for: url))

    #expect(restored.standardizedFileURL == url.standardizedFileURL)
}

@Test func storedPathSurvivesAChangedContainerUUID() {
    // Хранимый путь не должен содержать ничего от контейнера.
    let url = LibraryPathStore.libraryRoot.appendingPathComponent("Моя музыка/track.mp3")
    let stored = LibraryPathStore.storedPath(for: url)

    #expect(!stored.contains("/var/mobile"))
    #expect(!stored.hasPrefix("/"))
}

@Test func urlOutsideLibraryRootIsStoredAbsolutely() {
    let outside = URL(fileURLWithPath: "/tmp/somewhere/track.mp3")

    #expect(LibraryPathStore.storedPath(for: outside) == "/tmp/somewhere/track.mp3")
}
```

- [ ] **Step 2: Прогнать тесты и убедиться, что они падают**

```bash
xcodebuild test -scheme Musify -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' 2>&1 | grep -E "cannot find|failed|error:"
```

Expected: FAIL — `cannot find 'LibraryPathStore' in scope`

- [ ] **Step 3: Реализовать шов**

Создать `Utilities/LibraryPathStore.swift`:

```swift
import Foundation

/// Шов путей: переводит между тем, что лежит в базе, и рабочим `URL`.
///
/// На macOS библиотека может лежать где угодно, поэтому путь хранится
/// абсолютным. На iOS музыка всегда внутри контейнера приложения, а UUID
/// контейнера не стабилен между установками — там хранится путь относительно
/// `Documents`, а абсолютный собирается в рантайме.
enum LibraryPathStore {
    /// Корень, относительно которого хранятся пути.
    static var libraryRoot: URL {
        #if os(iOS)
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #else
        URL(fileURLWithPath: "/")
        #endif
    }

    /// Путь для записи в базу.
    static func storedPath(for url: URL) -> String {
        let root = libraryRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path

        #if os(iOS)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
        #else
        return path
        #endif
    }

    /// Рабочий `URL` из того, что лежит в базе.
    static func url(fromStored path: String) -> URL {
        guard !path.hasPrefix("/") else { return URL(fileURLWithPath: path) }
        return libraryRoot.appendingPathComponent(path)
    }
}
```

- [ ] **Step 4: Прогнать тесты**

```bash
xcodebuild test -scheme Musify -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' 2>&1 | grep -E "passed|failed"
```

Expected: все четыре теста проходят.

- [ ] **Step 5: Коммит**

```bash
git add Utilities/LibraryPathStore.swift Tests/MusifyTests/LibraryPathStoreTests.swift
git commit -m "feat: add path seam for container-relative track paths"
```

---

### Task 4: Провести Track и Folder через шов путей

**Files:**
- Modify: `Models/Core/Track.swift:129` (чтение) и `Models/Core/Track.swift:174` (запись)
- Modify: `Models/Core/Folder.swift`
- Test: `Tests/MusifyTests/TrackPersistenceTests.swift`

**Interfaces:**
- Consumes: `LibraryPathStore.storedPath(for:)`, `LibraryPathStore.url(fromStored:)` из Task 3
- Produces: `Track` и `Folder`, чьи `url` восстанавливаются из относительного пути

- [ ] **Step 1: Написать падающий тест**

Создать `Tests/MusifyTests/TrackPersistenceTests.swift`:

```swift
import Foundation
import GRDB
import Testing
@testable import Musify

@Test func trackWritesRelativePathAndReadsItBack() throws {
    let dbQueue = try DatabaseQueue()
    try dbQueue.write { db in
        try db.create(table: "tracks") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("path", .text).notNull()
            t.column("title", .text)
            t.column("artist", .text)
            t.column("album", .text)
        }
    }

    let url = LibraryPathStore.libraryRoot.appendingPathComponent("Моя музыка/track.mp3")
    let track = Track(url: url)

    try dbQueue.write { db in try track.insert(db) }

    let storedPath = try dbQueue.read { db in
        try String.fetchOne(db, sql: "SELECT path FROM tracks LIMIT 1")
    }
    #expect(storedPath == "Моя музыка/track.mp3")

    let loaded = try dbQueue.read { db in try Track.fetchOne(db) }
    #expect(loaded?.url.standardizedFileURL == url.standardizedFileURL)
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Expected: FAIL — в базу пишется абсолютный путь `/var/mobile/.../Documents/Моя музыка/track.mp3`.

- [ ] **Step 3: Заменить кодирование пути в Track**

В `Models/Core/Track.swift` строка чтения:

```swift
let path: String = row[Columns.path]
self.url = LibraryPathStore.url(fromStored: path)
```

и строка записи:

```swift
container[Columns.path] = LibraryPathStore.storedPath(for: url)
```

- [ ] **Step 4: Сделать то же для Folder**

В `Models/Core/Folder.swift` заменить кодирование и декодирование `path` теми же двумя вызовами. Дополнительно на iOS не сохранять bookmark:

```swift
#if os(iOS)
container[Columns.bookmarkData] = nil
#else
container[Columns.bookmarkData] = bookmarkData
#endif
```

- [ ] **Step 5: Прогнать тесты**

Expected: PASS, включая тесты из Task 3.

- [ ] **Step 6: Коммит**

```bash
git add Models/Core/Track.swift Models/Core/Folder.swift Tests/MusifyTests/TrackPersistenceTests.swift
git commit -m "feat: store track and folder paths relative to the library root"
```

---

### Task 5: База данных на iOS

**Files:**
- Modify: `Managers/Database/DatabaseManager.swift:41`
- Test: ручная проверка запуска

**Interfaces:**
- Consumes: ничего
- Produces: файл базы `musify.db` в `Application Support/com.sereja.musify/`

- [ ] **Step 1: Вывести имя файла базы из bundle id**

Заменить строку 41:

```swift
let appName = bundleID.split(separator: ".").last.map(String.init) ?? "library"
let dbFilename = bundleID.hasSuffix(".debug") ? "\(appName)-debug.db" : "\(appName).db"
```

На маке это по-прежнему даст `Petrichor.db` вместо `petrichor.db` — поэтому привести к нижнему регистру: `appName.lowercased()`. Для мак-таргета имя файла остаётся `petrichor.db`, существующая база продолжает открываться.

- [ ] **Step 2: Запустить приложение в симуляторе**

```bash
xcodebuild -scheme Musify -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build
```

Затем через iOS Simulator MCP: `launch` собранный `.app`, проверить, что приложение не падает на старте.

- [ ] **Step 3: Убедиться, что база создалась**

```bash
find ~/Library/Developer/CoreSimulator/Devices -name "musify.db" -newermt "-5 minutes" 2>/dev/null | head -2
```

Expected: файл найден.

- [ ] **Step 4: Коммит**

```bash
git add Managers/Database/DatabaseManager.swift
git commit -m "feat: derive the database filename from the bundle identifier"
```

---

### Task 6: Открыть папку приложения для Finder и «Файлов»

**Files:**
- Modify: `Configuration/Info-iOS.plist`

**Interfaces:**
- Consumes: ничего
- Produces: папка `Documents` приложения, видимая в Finder по кабелю и в системном «Файлы»

- [ ] **Step 1: Добавить ключи**

В `Configuration/Info-iOS.plist`:

```xml
<key>UIFileSharingEnabled</key>
<true/>
<key>LSSupportsOpeningDocumentsInPlace</key>
<true/>
```

- [ ] **Step 2: Проверить, что UIBackgroundModes содержит audio**

Ключ уже присутствует в файле — убедиться, что значение именно такое:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

- [ ] **Step 3: Пересобрать и запустить**

Приложение должно запускаться без падений; визуально ничего не меняется.

- [ ] **Step 4: Коммит**

```bash
git add Configuration/Info-iOS.plist
git commit -m "feat: expose the app documents folder to Finder and Files"
```

---

### Task 7: Сканирование папки Documents

Изначальный вариант этой задачи предлагал написать новый `FolderScanner` с
собственным обходом файловой системы и своим списком расширений, а также
несуществующий метод `LibraryManager.processScannedFiles(_:in:)`. Это
дублировало бы уже существующий конвейер сканирования
(`DatabaseManager.addFoldersAsync` → `scanFoldersForTracks`), который на
macOS запускается из `addFolder()` и уже умеет дедупликацию, метаданные,
прогресс и удаление исчезнувших файлов. iOS-точка входа переиспользует этот
конвейер напрямую, а не копирует его логику.

**Files:**
- Modify: `Managers/Library/LMFolders.swift`
- Modify: `Utilities/LibraryPathStore.swift` — `storedPath(for:)` не обрабатывал
  случай, когда переданный `URL` равен самому `libraryRoot` (проверка `hasPrefix`
  требует конечный `/`, которого у самого корня нет), и в этом случае писал в базу
  абсолютный путь. Это стало заметно только когда Task 7 впервые передала в
  `storedPath(for:)` сам `libraryRoot` (регистрация корня как папки библиотеки)
- Test: `Tests/MusifyTests/FolderScanTests.swift`
- Test: `Tests/MusifyTests/LibraryPathStoreTests.swift` — тест на этот же edge case

**Interfaces:**
- Consumes: `LibraryPathStore.libraryRoot` из Task 3; `DatabaseManager.addFoldersAsync(_:bookmarkDataMap:)`
  и `DatabaseManager.scanFoldersForTracks(_:showActivityInTray:isInitialScan:)` (существующий конвейер,
  `Managers/Database/DMFolders.swift`); `AudioFormat.supportedExtensions` (`Utilities/Constants.swift`)
  как канонический список расширений
- Produces: `LibraryManager.scanLibraryRoot() async throws` — регистрирует `Documents`
  как единственную папку библиотеки и сканирует её

- [ ] **Step 1: Изучить существующий конвейер**

`addFolder(urls:)` (макошная версия и уже реализованная iOS-версия в
`LMFolders.swift`) создают security-scoped bookmarks и обрабатывают
iCloud-догрузку, затем вызывают `databaseManager.addFolders(urls:bookmarkDataMap:)`,
который внутри вызывает `addFoldersAsync`, который сам вызывает
`scanFoldersForTracks` для добавленных папок. Ни bookmarks, ни iCloud-логика
iOS-корню не нужны: `Documents` лежит внутри контейнера приложения,
разрешения не требуются.

- [ ] **Step 2: Добавить точку входа**

В `LMFolders.swift`, внутри существующего `#if os(macOS) ... #else ... #endif`
(iOS-ветка), рядом с `addFolder(urls:)`:

```swift
/// iOS entry point: the library *is* the app's own `Documents` folder — no
/// picker, no security-scoped bookmark. Registers `LibraryPathStore.libraryRoot`
/// as the library's folder and reuses the same `addFoldersAsync` →
/// `scanFoldersForTracks` pipeline every other folder goes through.
func scanLibraryRoot() async throws {
    let root = LibraryPathStore.libraryRoot
    let folders = try await databaseManager.addFoldersAsync([root], bookmarkDataMap: [:])
    guard !folders.isEmpty else { return }
    await MainActor.run {
        self.scheduleLibraryReload()
    }
}
```

Вызывать повторно безопасно: `addFoldersAsync` находит уже
зарегистрированную папку по хранимому пути (см. Часть А правки в
`DMFolders.swift`) и просто пересканирует её.

- [ ] **Step 3: Прогресс сканирования**

Отдельного колбэка прогресса не заводится. `scanFoldersForTracks` уже
публикует прогресс двумя каналами: `DatabaseManager.isScanning` /
`scanStatusMessage` (`@Published`) и `NotificationManager.shared`
(`startActivity` / `updateActivityProgress` / `stopActivity`). Экран,
показывающий прогресс сканирования, подписывается на них напрямую.

- [ ] **Step 4: Тесты**

`DatabaseManager` не даёт подставить in-memory `DatabaseQueue` (единственный
инициализатор — параметризованный `init() throws`, открывающий реальный файл
в Application Support), поэтому `scanLibraryRoot()` целиком не покрыт
модульным тестом. Тестами покрыто то, от чего он зависит:

- `AudioFormat.supportedExtensions` — не пуст, не содержит ничего из
  `unsupportedExtensions`/`withheldExtensions` (список расширений здесь берётся
  из реального движка метаданных, а не выдуман, как в исходной версии задачи —
  на iOS сейчас это только `mp3`, пока `AVAssetMetadataReader` не расширят в
  Task 8);
- регистрация корня библиотеки как `Folder` пишет в столбец `path` пустую
  строку (относительный путь для самого корня), а не абсолютный путь
  контейнера — через ту же in-memory GRDB-схему, что и `PathQueryTests.swift`;
- `LibraryPathStore.storedPath(for: LibraryPathStore.libraryRoot) == ""` и
  обратное преобразование возвращает исходный `libraryRoot`.

- [ ] **Step 5: Коммит**

```bash
git add Managers/Library/LMFolders.swift Utilities/LibraryPathStore.swift \
    Tests/MusifyTests/FolderScanTests.swift Tests/MusifyTests/LibraryPathStoreTests.swift
git commit -m "feat: scan the documents folder as the iOS library root"
```

---

### Task 8: Метаданные через AVAsset

**Files:**
- Modify: `iOS/AVAssetMetadataReader.swift`
- Test: `Tests/MusifyTests/MetadataMappingTests.swift`

**Interfaces:**
- Consumes: `MetadataEngine` из `Core/Metadata/MetadataEngine.swift`
- Produces: заполненный `Track` с `title`, `artist`, `album`, `duration`, обложкой и фолбэком по имени файла

Разбора имени файла вида «Исполнитель - Название» в проекте не было вообще:
в `Managers/Database/DMMetadata.swift:14-15` есть только фолбэк `title` → имя
файла целиком и `artist` → `"Unknown Artist"`, никакого разбора на части там
нет и выносить нечего. Тип `FilenameMetadataFallback` пишется с нуля.

Правило «ровно ≥3 части и числовой префикс» из исходной версии этой задачи
покрывает не тот случай. Замер по библиотеке пользователя (2824 mp3):
1082 файла имеют числовой префикс вида `0239 - Исполнитель - Название.mp3`
(префикс задаёт порядок в плейлистах и остаётся частью заголовка), но файлы,
у которых реально отсутствует тег исполнителя, чаще выглядят как обычный
`Исполнитель - Название.mp3` без префикса: `System of a down - Violent
pornography.mp3`, `avatar the last airbender - safe return.mp3`, `Jaden - The
Passion.mp3`. Правило «≥3 части» на них не срабатывает — `artist` остаётся
`nil` именно там, где фолбэк нужнее всего. Поэтому реализованы оба случая:

- `#### - Исполнитель - Название` (первая часть целиком из цифр, частей ≥3):
  `artist` = вторая часть, `title` = имя файла целиком без расширения
  (с префиксом);
- `Исполнитель - Название` (частей ≥2, первая часть не из цифр): `artist` =
  первая часть, `title` = остальное, склеенное обратно через `" - "`;
- одна часть (`Just A Song.mp3`): `artist == nil`, `title` = имя файла без
  расширения.

Разделитель — `" - "` (пробел-дефис-пробел). Результат обрезается по краям
пробелов.

- [ ] **Step 1: Написать падающий тест на фолбэк**

Создать `Tests/MusifyTests/MetadataMappingTests.swift`:

```swift
import Foundation
import Testing
@testable import Musify

@Test func filenameFallbackExtractsArtistAndKeepsPrefixedTitle() {
    let url = URL(fileURLWithPath: "/tmp/0239 - Jeune Ras - Ruff Ryder - Remix.mp3")

    let parsed = FilenameMetadataFallback.parse(url)

    #expect(parsed.artist == "Jeune Ras")
    #expect(parsed.title == "0239 - Jeune Ras - Ruff Ryder - Remix")
}

@Test func filenameWithoutNumericPrefixIsLeftAlone() {
    let url = URL(fileURLWithPath: "/tmp/Just A Song.mp3")

    let parsed = FilenameMetadataFallback.parse(url)

    #expect(parsed.artist == nil)
    #expect(parsed.title == "Just A Song")
}

@Test func plainArtistDashTitleExtractsArtist() {
    let url = URL(fileURLWithPath: "/tmp/System of a down - Violent pornography.mp3")

    let parsed = FilenameMetadataFallback.parse(url)

    #expect(parsed.artist == "System of a down")
    #expect(parsed.title == "Violent pornography")
}
```

Полный набор тестов (с ещё четырьмя случаями — smash-case из имён,
многодефисные названия, обрезка пробелов) лежит в
`Tests/MusifyTests/MetadataMappingTests.swift`.

- [ ] **Step 2: Прогнать и убедиться, что падает**

Expected: FAIL — `cannot find 'FilenameMetadataFallback' in scope`

- [ ] **Step 3: Реализовать фолбэк**

Тип пишется с нуля в `iOS/AVAssetMetadataReader.swift` (см. обоснование
правила выше):

```swift
enum FilenameMetadataFallback {
    private static let separator = " - "

    static func parse(_ url: URL) -> (artist: String?, title: String) {
        let base = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespaces)
        let parts = base.components(separatedBy: separator)

        guard parts.count >= 2 else {
            return (nil, base)
        }

        // `#### - Исполнитель - Название`: префикс остаётся частью заголовка.
        if parts.count >= 3, !parts[0].isEmpty, parts[0].allSatisfy(\.isNumber) {
            let artist = parts[1].trimmingCharacters(in: .whitespaces)
            return (artist, base)
        }

        // `Исполнитель - Название`.
        guard !parts[0].isEmpty, !parts[0].allSatisfy(\.isNumber) else {
            return (nil, base)
        }

        let artist = parts[0].trimmingCharacters(in: .whitespaces)
        let title = parts.dropFirst().joined(separator: separator)
            .trimmingCharacters(in: .whitespaces)
        return (artist, title)
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Expected: все тесты проходят.

- [ ] **Step 5: Подключить фолбэк к читателю метаданных**

В `AVAssetMetadataReader.extractMetadata` после чтения тегов: если
`metadata.artist` пуст/`nil` — подставить `artist` из
`FilenameMetadataFallback.parse`; если пуст/`nil` `metadata.title` — подставить
`title` оттуда же. Плейсхолдер `"Unknown Artist"` подставляется не здесь, а
позже в общем коде (`DMMetadata.swift:15`), поэтому ридер проверяет именно
пустоту/`nil`, а не сравнение со строкой `"Unknown Artist"`.

- [ ] **Step 6: Коммит**

```bash
git add iOS/AVAssetMetadataReader.swift Tests/MusifyTests/MetadataMappingTests.swift
git commit -m "feat: fall back to filename metadata when tags are missing"
```

---

### Task 9: Бэкенд воспроизведения на AVQueuePlayer — очередь

Самая большая задача плана. Реализует `PlaybackBackend` целиком; текущий `AVAudioPlaybackBackend` удаляется.

Реализованный код в `iOS/AVQueuePlayerBackend.swift` расходится с примером ниже
в четырёх местах:

- **`backendStateChanged(with:previous:)` в примере отсутствовал вообще**,
  хотя метод есть в `PlaybackBackendDelegate`. Реализован через KVO на
  `player.timeControlStatus` (`AVPlayer.TimeControlStatus` не имеет случая
  "остановлено" — пустая очередь маппится в `.stopped`, как и в старом
  `AVAudioPlaybackBackend`). Уведомление шлётся не только из KVO-колбэка, но
  и явно после каждой мутации, способной поменять `entries.isEmpty`
  (`setQueue`, `clearQueue`, `removeQueueEntry`, `pause`/`resume`/`stop`/
  `togglePlayPause`) — иначе переход "пусто → есть очередь, на паузе" не
  генерировал бы уведомление вовсе, потому что сам `timeControlStatus` при
  этом не меняется.
- **Поток вызова делегата.** KVO-колбэки AVFoundation не гарантируют, на
  каком потоке они придут. `CrescendoPlaybackBackend` (мак) всегда зовёт
  `backendDelegate` с главного потока — там это происходит по конструкции,
  через `@MainActor`-мост. Здесь такого моста нет, поэтому добавлен
  `runOnMain(_:)` (прямой вызов, если уже на главном потоке, иначе
  `DispatchQueue.main.async`), и через него проходит каждый вызов
  `backendDelegate`.
- **`setNowPlayingMetadata(_:)` — пустая реализация** (`func
  setNowPlayingMetadata(_ metadata: NowPlayingMetadata?) {}`), чтобы тип
  соответствовал протоколу; полная реализация — Task 10.
- **Исправлена ошибка в примере из Step 3**: в обработчике смены
  `currentItem` пример вычислял `duration` для только что закончившегося
  трека уже после того, как `player.currentItem` указывал на следующий —
  `backendDidFinishPlaying` получал бы длительность нового трека вместо
  закончившегося. Исправлено чтением `finished.duration.seconds` у самого
  старого `AVPlayerItem` (KVO-колбэк отдаёт его в `change.oldValue`, объект
  остаётся валиден и после того, как перестал быть `currentItem`).

Тесты из Step 1 конструируют `QueueEntry` с URL на несуществующие
`/tmp/*.mp3` — это безопасно: `queue`, `queueIndex(of:)` и `hasQueuedSuccessor`
читаются из собственного массива `entries`, а не из `AVQueuePlayer`.
`AVPlayerItem(url:)` не проверяет существование файла синхронно (загрузка
асинхронная и ленивая), и все тесты используют `startPaused: true`, так что
плеер не пытается ничего проигрывать и не имеет повода досрочно убрать
элементы из своей внутренней очереди.

**Files:**
- Create: `iOS/AVQueuePlayerBackend.swift`
- Delete: `iOS/AVAudioPlaybackBackend.swift`
- Modify: `Core/Playback/PlaybackEngine.swift`
- Test: `Tests/MusifyTests/QueueBackendTests.swift`

**Interfaces:**
- Consumes: протокол `PlaybackBackend`, типы `QueueEntry`, `AudioEntryId`, `AudioPlayerState`, `NowPlayingMetadata`, `EqualizerPreset` из `Core/Playback/PlaybackEngine.swift`
- Produces: `final class AVQueuePlayerBackend: NSObject, PlaybackBackend`

- [ ] **Step 1: Написать падающие тесты на очередь**

Создать `Tests/MusifyTests/QueueBackendTests.swift`:

```swift
import Foundation
import Testing
@testable import Musify

private func makeEntry(_ name: String) -> QueueEntry {
    QueueEntry(entryId: AudioEntryId(id: name), url: URL(fileURLWithPath: "/tmp/\(name).mp3"))
}

@Test func setQueueInstallsEntriesInOrder() {
    let backend = AVQueuePlayerBackend()
    let entries = [makeEntry("a"), makeEntry("b"), makeEntry("c")]

    backend.setQueue(entries, startingAt: 0, startPaused: true)

    #expect(backend.queue.map(\.id) == ["a", "b", "c"])
}

@Test func insertNextPlacesEntryRightAfterCurrent() {
    let backend = AVQueuePlayerBackend()
    backend.setQueue([makeEntry("a"), makeEntry("b")], startingAt: 0, startPaused: true)

    backend.insertNext(makeEntry("x"))

    #expect(backend.queue.map(\.id) == ["a", "x", "b"])
    #expect(backend.hasQueuedSuccessor)
}

@Test func removingTheOnlySuccessorClearsTheFlag() {
    let backend = AVQueuePlayerBackend()
    backend.setQueue([makeEntry("a"), makeEntry("b")], startingAt: 0, startPaused: true)

    backend.removeQueueEntry(id: AudioEntryId(id: "b"))

    #expect(backend.hasQueuedSuccessor == false)
    #expect(backend.queueIndex(of: AudioEntryId(id: "b")) == nil)
}

@Test func shuffleKeepsPlayedAndCurrentInPlace() {
    let backend = AVQueuePlayerBackend()
    let entries = (0..<10).map { makeEntry("t\($0)") }
    backend.setQueue(entries, startingAt: 2, startPaused: true)

    backend.shuffleQueue()

    #expect(backend.queue.prefix(3).map(\.id) == ["t0", "t1", "t2"])
    #expect(backend.queue.count == 10)
}
```

Сигнатуры сверены с `Core/Playback/PlaybackEngine.swift:55-84`: `AudioEntryId(id: String)`, `QueueEntry(entryId: AudioEntryId, url: URL)`. Свойство `queue` возвращает `[AudioEntryId]`, поэтому `.map(\.id)` даёт строки.

- [ ] **Step 2: Прогнать и убедиться, что падает**

Expected: FAIL — `cannot find 'AVQueuePlayerBackend' in scope`

- [ ] **Step 3: Реализовать очередь и транспорт**

Создать `iOS/AVQueuePlayerBackend.swift`:

```swift
import AVFoundation
import Foundation
import MediaPlayer

/// iOS-адаптер `PlaybackBackend`.
///
/// Построен на `AVQueuePlayer`, потому что бесшовный переход между треками —
/// свойство архитектуры очереди, а не настройка. Эквалайзер на iOS не
/// поддерживается: методы EQ ничего не делают.
final class AVQueuePlayerBackend: NSObject, PlaybackBackend {
    weak var backendDelegate: PlaybackBackendDelegate?

    private let player = AVQueuePlayer()
    private var entries: [QueueEntry] = []
    private var currentIndex: Int = 0
    private var itemObservation: NSKeyValueObservation?

    override init() {
        super.init()
        player.actionAtItemEnd = .advance
        observeTrackChanges()
    }

    // MARK: - State

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var state: AudioPlayerState {
        if player.timeControlStatus == .playing { return .playing }
        return entries.isEmpty ? .stopped : .paused
    }

    var currentPlaybackProgress: Double {
        guard duration > 0 else { return 0 }
        return player.currentTime().seconds / duration
    }

    var duration: Double {
        player.currentItem?.duration.seconds ?? 0
    }

    // MARK: - Queue

    var queue: [AudioEntryId] { entries.map(\.entryId) }

    func queueIndex(of entryId: AudioEntryId) -> Int? {
        entries.firstIndex { $0.entryId == entryId }
    }

    var hasQueuedSuccessor: Bool { currentIndex + 1 < entries.count }

    func setQueue(_ newEntries: [QueueEntry], startingAt index: Int, startPaused: Bool) {
        entries = newEntries
        currentIndex = max(0, min(index, newEntries.count - 1))
        rebuildPlayerItems(startPaused: startPaused)
    }

    func insert(_ entry: QueueEntry, at index: Int) {
        let position = max(0, min(index, entries.count))
        entries.insert(entry, at: position)
        if position <= currentIndex { currentIndex += 1 }
        refillUpcomingItems()
    }

    func append(_ entry: QueueEntry) {
        entries.append(entry)
        refillUpcomingItems()
    }

    func insertNext(_ entry: QueueEntry) {
        insert(entry, at: currentIndex + 1)
    }

    func move(from source: Int, to destination: Int) {
        guard entries.indices.contains(source) else { return }
        let entry = entries.remove(at: source)
        entries.insert(entry, at: max(0, min(destination, entries.count)))
        refillUpcomingItems()
    }

    func removeQueueEntry(at index: Int) {
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
        if index < currentIndex { currentIndex -= 1 }
        refillUpcomingItems()
    }

    func removeQueueEntry(id: AudioEntryId) {
        guard let index = queueIndex(of: id) else { return }
        removeQueueEntry(at: index)
    }

    func clearQueue() {
        entries.removeAll()
        currentIndex = 0
        player.removeAllItems()
    }

    func playQueueEntry(at index: Int, startPaused: Bool) {
        guard entries.indices.contains(index) else { return }
        currentIndex = index
        rebuildPlayerItems(startPaused: startPaused)
    }

    func shuffleQueue() {
        guard currentIndex + 1 < entries.count else { return }
        let head = entries[...currentIndex]
        let tail = entries[(currentIndex + 1)...].shuffled()
        entries = Array(head) + tail
        refillUpcomingItems()
    }

    // MARK: - Player items

    /// Ставит текущий трек и всё, что за ним: успешник уже загружен в плеер,
    /// поэтому переход происходит без паузы.
    private func rebuildPlayerItems(startPaused: Bool) {
        player.removeAllItems()
        for entry in entries[currentIndex...] {
            player.insert(AVPlayerItem(url: entry.url), after: nil)
        }
        if startPaused { player.pause() } else { player.play() }
    }

    /// Пересобирает только ещё не прозвучавший хвост, не трогая играющий трек.
    private func refillUpcomingItems() {
        guard player.currentItem != nil else { return }
        for item in player.items().dropFirst() { player.remove(item) }
        for entry in entries.dropFirst(currentIndex + 1) {
            player.insert(AVPlayerItem(url: entry.url), after: nil)
        }
    }

    /// AVQueuePlayer сам переходит на следующий элемент без паузы. Смена
    /// `currentItem` — единственный сигнал о том, что трек закончился и
    /// заиграл следующий, поэтому оба события делегата шлются отсюда.
    private func observeTrackChanges() {
        itemObservation = player.observe(\.currentItem, options: [.old, .new]) { [weak self] player, change in
            guard let self else { return }

            if let finished = change.oldValue ?? nil, finished !== player.currentItem {
                let finishedIndex = self.currentIndex
                if self.entries.indices.contains(finishedIndex) {
                    self.backendDelegate?.backendDidFinishPlaying(
                        entryId: self.entries[finishedIndex].entryId,
                        stopReason: .eof,
                        progress: 1.0,
                        duration: self.duration
                    )
                }
                self.currentIndex = min(finishedIndex + 1, max(0, self.entries.count - 1))
            }

            guard player.currentItem != nil, self.entries.indices.contains(self.currentIndex) else { return }
            let started = self.entries[self.currentIndex].entryId
            self.backendDelegate?.backendDidStartPlaying(with: started)
            self.backendDelegate?.backendDidFinishBuffering(with: started)
        }
    }
}
```

Методы делегата сверены с `Core/Playback/PlaybackEngine.swift:231-243`: `backendDidStartPlaying(with:)`, `backendStateChanged(with:previous:)`, `backendDidFinishPlaying(entryId:stopReason:progress:duration:)`, `backendUnexpectedError(error:)`, `backendDidFinishBuffering(with:)`, `backendDidSkipQueueEntry(entryId:)`. Метода для отчёта о прогрессе в протоколе нет — прогресс движок читает сам через `currentPlaybackProgress`.

- [ ] **Step 4: Реализовать транспорт и эффекты**

Дописать в тот же файл:

```swift
extension AVQueuePlayerBackend {
    func pause() { player.pause() }
    func resume() { player.play() }

    func stop() {
        player.pause()
        clearQueue()
    }

    func togglePlayPause() {
        player.timeControlStatus == .playing ? player.pause() : player.play()
    }

    @discardableResult
    func seek(to time: Double) -> Bool {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        return true
    }

    @discardableResult
    func seekForward(_ seconds: Double) -> Bool {
        seek(to: player.currentTime().seconds + seconds)
    }

    @discardableResult
    func seekBackward(_ seconds: Double) -> Bool {
        seek(to: max(0, player.currentTime().seconds - seconds))
    }

    // Эквалайзер и расширение стереобазы на iOS не поддерживаются.
    func setStereoWidening(enabled: Bool) {}
    func isStereoWideningEnabled() -> Bool { false }
    func setEQEnabled(_ enabled: Bool) {}
    func isEQEnabled() -> Bool { false }
    func applyEQPreset(_ preset: EqualizerPreset) {}
    func applyEQCustom(gains: [Float]) {}
    func setPreamp(_ gain: Float) {}
    func getPreamp() -> Float { 0 }
}
```

- [ ] **Step 5: Переключить движок на новый бэкенд**

В `Core/Playback/PlaybackEngine.swift` заменить в инициализаторе:

```swift
#if os(macOS)
self.backend = CrescendoPlaybackBackend()
#else
self.backend = AVQueuePlayerBackend()
#endif
```

Удалить старый файл:

```bash
git rm iOS/AVAudioPlaybackBackend.swift
```

- [ ] **Step 6: Прогнать тесты**

Expected: все тесты очереди проходят.

- [ ] **Step 7: Коммит**

```bash
git add iOS/AVQueuePlayerBackend.swift Core/Playback/PlaybackEngine.swift Tests/MusifyTests/QueueBackendTests.swift
git commit -m "feat: replace the iOS playback backend with a gapless AVQueuePlayer one"
```

---

### Task 10: Аудиосессия, фон и блокировочный экран

**Files:**
- Create: `iOS/AudioSessionController.swift`
- Create: `iOS/NowPlayingPublisher.swift`
- Modify: `iOS/AVQueuePlayerBackend.swift`

**Interfaces:**
- Consumes: `AVQueuePlayerBackend` из Task 9, `NowPlayingMetadata` из `Core/Playback/PlaybackEngine.swift`
- Produces:
  - `final class AudioSessionController` с `func activate()`
  - `enum NowPlayingPublisher` с `static func publish(_ metadata: NowPlayingMetadata?, progress: Double, duration: Double)`

- [ ] **Step 1: Реализовать контроллер сессии**

Создать `iOS/AudioSessionController.swift`:

```swift
import AVFoundation

/// Настройка аудиосессии и реакция на прерывания.
///
/// Звонок или будильник ставят на паузу и возвращают воспроизведение;
/// выдернутые наушники ставят на паузу и не продолжают в динамик.
final class AudioSessionController {
    private let onPause: () -> Void
    private let onResume: () -> Void

    init(onPause: @escaping () -> Void, onResume: @escaping () -> Void) {
        self.onPause = onPause
        self.onResume = onResume
    }

    func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            onPause()
        case .ended:
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                onResume()
            }
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }

        if reason == .oldDeviceUnavailable { onPause() }
    }
}
```

- [ ] **Step 2: Реализовать публикацию Now Playing**

Создать `iOS/NowPlayingPublisher.swift`:

```swift
import MediaPlayer

/// Плитка «Сейчас играет» на блокировочном экране и в Пункте управления.
enum NowPlayingPublisher {
    static func publish(_ metadata: NowPlayingMetadata?, progress: Double, duration: Double) {
        guard let metadata else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: metadata.title ?? "",
            MPMediaItemPropertyArtist: metadata.artist ?? "",
            MPMediaItemPropertyAlbumTitle: metadata.albumTitle ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress * duration
        ]

        if let data = metadata.artworkData, let image = UIImage(data: data) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
```

Поля сверены с `Core/Playback/PlaybackEngine.swift:92-99`: `title`, `artist`, `albumTitle`, `albumArtist`, `genre` — все `String?`, обложка приходит байтами в `artworkData: Data?`.

- [ ] **Step 3: Подключить обе части к бэкенду**

В `AVQueuePlayerBackend`: создать `AudioSessionController` в `init` и вызвать `activate()`; в `setNowPlayingMetadata(_:)` вызвать `NowPlayingPublisher.publish`.

```swift
func setNowPlayingMetadata(_ metadata: NowPlayingMetadata?) {
    NowPlayingPublisher.publish(metadata, progress: currentPlaybackProgress, duration: duration)
}
```

- [ ] **Step 4: Собрать и убедиться, что тесты не сломались**

```bash
xcodebuild test -scheme Musify -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' 2>&1 | grep -E "passed|failed|error:"
```

- [ ] **Step 5: Коммит**

```bash
git add iOS/AudioSessionController.swift iOS/NowPlayingPublisher.swift iOS/AVQueuePlayerBackend.swift
git commit -m "feat: play in the background and publish the now playing tile"
```

---

### Task 11: Проверочный экран — библиотека играет

Временный экран, единственная задача которого — доказать, что цепочка «папка → база → очередь → звук» работает. В следующем плане он будет заменён настоящим интерфейсом.

**Files:**
- Create: `iOS/TrackListDebugView.swift`
- Modify: `iOS/PetrichorApp.swift` → переименовать в `iOS/MusifyApp.swift`

**Interfaces:**
- Consumes: `LibraryManager.scanLibraryRoot()` из Task 7, `PlaybackEngine` из Task 9
- Produces: экран со списком треков; тап запускает воспроизведение с этого места

- [ ] **Step 1: Написать экран**

Создать `iOS/TrackListDebugView.swift`:

```swift
import SwiftUI

/// Временный экран проверки цепочки. Заменяется настоящим интерфейсом
/// в плане «Musify: интерфейс».
struct TrackListDebugView: View {
    @Environment(LibraryManager.self) private var library
    @Environment(PlaybackManager.self) private var playback

    @State private var scanned = 0
    @State private var total = 0

    var body: some View {
        NavigationStack {
            List(library.tracks) { track in
                Button {
                    playback.play(track)
                } label: {
                    VStack(alignment: .leading) {
                        Text(track.title)
                        Text(track.artist ?? "—")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Musify")
            .overlay {
                if library.tracks.isEmpty {
                    ContentUnavailableView(
                        "Библиотека пуста",
                        systemImage: "music.note",
                        description: Text(total > 0 ? "Просканировано \(scanned) из \(total)" : "Скопируйте музыку в папку приложения")
                    )
                }
            }
            .task {
                await library.scanLibraryRoot { done, all in
                    scanned = done
                    total = all
                }
            }
        }
    }
}
```

Типы окружения (`LibraryManager`, `PlaybackManager`) и метод запуска трека взять фактические — как они прокидываются в `Application/AppCoordinator.swift`.

- [ ] **Step 2: Переименовать точку входа**

```bash
git mv iOS/PetrichorApp.swift iOS/MusifyApp.swift
```

Внутри переименовать структуру в `MusifyApp` и поставить `TrackListDebugView()` корневым экраном.

- [ ] **Step 3: Собрать и запустить в симуляторе**

Через iOS Simulator MCP: `attach`, затем `launch`. Скопировать в контейнер симулятора несколько mp3 для проверки:

```bash
SIM_DOCS=$(find ~/Library/Developer/CoreSimulator/Devices -type d -path "*com.sereja.musify/Documents" 2>/dev/null | head -1)
cp "/Users/sereja/Documents/Медиа (музыка:видео:изображения/Моя музыка/Spotify/Shazam/"*.mp3 "$SIM_DOCS" 2>/dev/null | head -5
```

- [ ] **Step 4: Проверить вручную**

Перезапустить приложение. Ожидается: список треков заполнился, тап по строке запускает звук, названия и исполнители читаются из тегов. Снять скриншот через `screenshot`.

- [ ] **Step 5: Коммит**

```bash
git add iOS/TrackListDebugView.swift iOS/MusifyApp.swift
git commit -m "feat: add a debug track list that plays the scanned library"
```

---

### Task 12: Первый выход на устройство

**Files:** изменений в коде нет.

**Interfaces:**
- Consumes: всё, что собрано в задачах 1-11
- Produces: работающее приложение на iPhone 16 Pro Max

- [ ] **Step 1: Подключить телефон и выбрать его целью**

```bash
xcrun devicectl list devices | grep -i "iPhone 16 Pro Max"
```

Expected: устройство в состоянии `available (paired)`.

- [ ] **Step 2: Настроить подпись**

В Xcode: таргет `Musify` → Signing & Capabilities → Team: личный Apple ID, Automatically manage signing — включено. Убедиться, что профиль выписан на `com.sereja.musify`.

- [ ] **Step 3: Установить на устройство**

```bash
xcodebuild -scheme Musify -destination 'platform=iOS,name=iPhone' build
```

Затем запустить с устройства — при первом запуске потребуется подтвердить доверие разработчику в Настройках → Основные → VPN и управление устройством.

- [ ] **Step 4: Залить тестовую папку**

Подключить iPhone кабелем, открыть его в Finder → вкладка «Файлы» → перетащить папку с 20-30 треками в Musify.

- [ ] **Step 5: Проверить сценарии**

Пройти вручную и зафиксировать результат:
- библиотека просканировалась, треки видны с корректными тегами;
- воспроизведение идёт, переход между треками без паузы;
- музыка продолжает играть с погашенным экраном;
- на блокировочном экране видны название, исполнитель и обложка, кнопки работают;
- пауза при отключении AirPods, без продолжения в динамик;
- повторная установка из Xcode не обнуляет библиотеку.

- [ ] **Step 6: Записать результат проверки**

Дописать раздел с результатами в `docs/superpowers/plans/2026-08-05-musify-foundation.md` и закоммитить:

```bash
git add docs/superpowers/plans/2026-08-05-musify-foundation.md
git commit -m "docs: record the first device checkpoint results"
```

---

## Что остаётся следующим планам

- **Интерфейс**: четыре вкладки, системный мини-плеер, Now Playing с текстом и очередью, списки, поиск, жесты. Заменяет `TrackListDebugView`.
- **Плейлисты, сеть и приёмка**: скрипт переписи путей в M3U, импорт плейлистов, тексты песен, фотографии артистов, экран настроек, перенос всей библиотеки на 20.9 ГБ и финальная приёмка.
