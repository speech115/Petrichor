# Petrichor iOS — правила репозитория

Форк `kushalpandya/Petrichor` (MIT © Kushal Pandya). Один проект, два таргета:
`Petrichor` (macOS 14+) и `PetrichoriOS` (iOS 26+). Работа идёт в `main`.

Канон дизайна: спека
`docs/superpowers/specs/2026-08-05-petrichor-ios-design.md` — замороженный
исторический документ (2026-08-09); живой канон — `CONTEXT.md` и `docs/adr/`.
Расхождение кода со спекой дефектом кода не считается.

## Ветки и PR

- `main` — единственная долгоживущая ветка. Новая работа начинается в короткой
  тематической ветке от актуального `main` и возвращается PR-ом в `main`.
- PR открывается draft-ом после первого цельного коммита и становится ready
  после зелёного CI: SwiftLint, actionlint, macOS Build & Analyze, iOS Build &
  Test и Release Build Check. Изменения SwiftUI дополнительно проверяются в
  симуляторе или на устройстве.
- Агент сам мёржит свой PR после зелёного CI (`gh pr merge`). Если PR меняет
  поведение приложения, сначала ставь сборку на телефон и жди, пока Сергей
  подтвердит исправление на устройстве.
- PR служит для diff, ревью и проверок. Трекер задач остаётся локальным в
  `.scratch/`; GitHub Issues для этого не используются.
- В описании PR есть раздел «Проверка»: какие тесты добавлены, что падало до
  изменения, что проверено на симуляторе или устройстве.
- Обновления апстрима берутся из remote `upstream`
  (`kushalpandya/Petrichor`) и вливаются в `main` как обычная работа.

## Agent skills

### Issue tracker

Локальный markdown: задачи и спеки лежат в `.scratch/<feature>/`. Удалённого
трекера нет — remote `origin` (приватный форк `speech115/Petrichor`) служит
только для бэкапа веток, не для тикетов. См. `docs/agents/issue-tracker.md`.

### Triage labels

Канонические пять ролей без переименований. См. `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` в корне и `docs/adr/`. Оба создаются лениво, когда
термин или решение действительно фиксируются. См. `docs/agents/domain.md`.

## Шесть швов — и только они

Платформенные различия сходятся ровно в шести местах:

| Шов | Интерфейс | macOS | iOS |
|---|---|---|---|
| Воспроизведение | `PlaybackBackend` | `CrescendoPlaybackBackend` | `AVQueuePlayerBackend` |
| Чтение метаданных | `MetadataEngine` | `CrescendoMetadataReader` | `AVAssetMetadataReader` |
| Изображения | `PlatformImage` | `NSImage` | `UIImage` |
| Пути к файлам | `LibraryPathStore` | абсолютный путь | путь от `Documents` |
| Журнал прослушиваний | `PlaybackJournal` | `Application Support/<bundle>/Sync` | `Documents/Sync` |
| Цветовая схема | `AppearanceApplier` | `NSApp.appearance` | `UIWindow.overrideUserInterfaceStyle` |

**Новые `#if os(...)` вне этих швов и вне `Views/` — нарушение дизайна.** Если
различие не влезает в существующий шов, нужен новый шов, а не разветвление по
месту вызова. Ветка `#if` в точке использования расползается: она не даёт одного
места, где поведение платформы можно прочитать целиком.

## Где чей интерфейс

- `Views/` — **только macOS**. Ветки `#if os(iOS)` внутри них — наследие, которое
  вычищается по мере переезда, а не образец для подражания.
- `iOS/` — все экраны iPhone, пишутся заново, а не адаптируются из макошных.

Причина не в чистоте: `Table` с сортируемыми колонками и `Table` c
`columnCustomization` не превращаются в телефонный список настройкой, и попытка
обслужить обе платформы одним файлом даёт худший вариант каждой.

## Общие слои

`Models`, `Core`, `Managers`, `Utilities` входят в оба таргета. AppKit задет в
шести файлах вне `Views` — разводится директивами внутри существующих файлов,
без копий и параллельных иерархий.

GRDB привязана к обоим таргетам. Crescendo остаётся macOS-only; вместе с ним
на iOS уходит FFmpeg, а с ним FLAC. Sparkle удалён: его лента — апстримная, а
форк обновления апстрима сам не принимает (ADR-0005).

## Пути к файлам

В базе хранится **путь относительно `Documents/`**, абсолютный собирается в
рантайме. UUID контейнера меняется при переустановке и восстановлении из бэкапа
и стабильным идентификатором не является. Security-scoped bookmarks на iOS
отключены: внутри своего контейнера разрешения не нужны.

Любой новый код, кодирующий `url.path` в базу напрямую, ломает это требование.

## Тесты — швы и чистая доменная логика

Места под автотесты: швы (резолв относительного пути, разбор M3U с сохранением
порядка, отображение метаданных `AVAsset`, сборка библиотеки из папки,
`PlaybackJournal`) **и чистые функции `Core/`, у которых много форм входа**:
`ArtistParser.parse` / `normalizeArtistName`, `M3UTrackResolver`,
`DMNormalization.albumKey`, `SeekScrub`, `LyricsTimeline`. Тесты на других
уровнях не пишутся: при переписывании интерфейса их поддержка стоит дороже пользы.

Исключение — регрессионный тест бага. Если баг живёт только в оркестрации
менеджеров (`PlaylistManager`, `PlaybackManager`, `AppCoordinator`, гонки
восстановления и скана) и чистой функции в `Core/`, на которой он воспроизводится,
нет, красный тест пишется на уровне менеджеров. Сначала стоит поискать, нельзя ли
вынести логику в чистую функцию; тест на менеджерах — когда нельзя.

На чистой логике тест проверяет **свойство, а не пример**: `@Test(arguments:)`
из Swift Testing по сгенерированным входам с фиксированным seed (генератор
живёт в `TestFixtures.swift`, сторонних библиотек нет). Кандидаты в свойства:
нормализация идемпотентна; `parse` не возвращает пустых имён и дублей;
резолв M3U сохраняет порядок; позиция после seek лежит в `[0, duration]`.
Если упало, минимальный падающий вход фиксируется отдельным примером.

SwiftUI-вьюхи тестами не покрываются. Их проверка — симулятор и устройство.

## Проверка вместо ревью

Абстрактное ревью («посмотри дифф и найди проблемы») не используется: оно
приносит придирки и YAGNI, а не баги. Вместо него:

- **Багфикс начинается с красного теста.** Тест воспроизводит баг и падает без
  фикса. В описании PR в разделе «Проверка» лежит вывод падения до фикса и
  зелёный прогон после. Баг во вьюхе или на устройстве, который тестом не
  ловится: шаги воспроизведения и подтверждение на симуляторе/устройстве.
- **Гипотезы вместо допроса.** Когда хочется ревью, сформулируй 3 проверяемые
  гипотезы о том, где изменение сломается (пустой плейлист; артист с `&` из
  списка известных; база v9 без новой колонки), и на каждую напиши тест.
  Упавший тест — находка, зелёный снимает гипотезу. Гипотеза, на которую
  нельзя написать тест, находкой не считается.
- **Ревью-агенты (code-reviewer из superpowers, pr-review-toolkit) по умолчанию
  не запускаются**, в том числе на шаге ревью в subagent-driven-development.
  Исключение — узкое ревью по триггеру, с одним вопросом:
  - concurrency: дифф трогает `actor`, `@MainActor`, `nonisolated`, `Task`,
    GRDB `DatabaseQueue`/`DatabasePool` → гонки и изоляция;
  - миграции БД: `DatabaseMigration.swift`, `DMBackgroundMigration.swift`,
    `DMSetup.swift` → открывается ли старая база; плюс тест миграции на
    фикстуре старой схемы;
  - контракт шва: меняется протокол одного из шести швов → обе реализации;
  - безопасность: `Secrets.xcconfig`, сетевые клиенты (Last.fm, био артистов),
    entitlements.
  Ответ узкого ревью — конкретные дефекты со сценарием воспроизведения. Стиль
  и «можно было бы» туда не пишутся: стиль держат SwiftLint и
  `CODING_STANDARDS.md`.

## Общие инженерные правила

- **Обратную совместимость не тянем.** Устаревшие пути удаляются, а не
  обкладываются слоями совместимости и фолбэками.
- Самая простая реализация, полностью закрывающая текущее требование.
  Спекулятивные абстракции и конфигурация — нет.
- Растим слоями: каждый шаг оставляет работающий продукт.
- Сначала смотрим, что уже есть в проекте и в зависимостях, потом пишем своё.

## Стиль кода

Стиль, не проверяемый линтером, — `CODING_STANDARDS.md`. Механика стиля —
`.swiftlint.yml`.

## Сборка

```bash
xcodebuild -scheme PetrichoriOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build
xcodebuild test -scheme PetrichoriOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```

Выход на реальный телефон — через скилл `.claude/skills/petrichor-device/`;
там же про автоматическое переподписание.
Обычный device destination на этой машине не работает: Xcode 26.6 против iOS 27
beta на устройстве. Не чините его, читайте скилл.

## Cursor Cloud specific instructions

The Cursor Cloud VM is **Linux x86_64**, not macOS. Petrichor is an Xcode-only
app (`Petrichor.xcodeproj`, no `Package.swift`) where ~half of the Swift files
import SwiftUI/AppKit/UIKit/AVFoundation. **The macOS and iOS targets cannot be
built, tested, run, or opened in a simulator on this VM** — that path needs
macOS 26 + Xcode 26.6 (see `README-iOS.md` and the `## Сборка` section above) or
the `.claude/skills/ios-simulator` / `.claude/skills/petrichor-device` skills on
an Apple host. Do not try to install Xcode, `swift`, or a simulator here, and do
not treat the missing build as an environment defect.

What *is* runnable on the Linux VM are the two Linux CI gates from
`.github/workflows/ci.yml` (the `lint` and `actionlint` jobs). The update script
installs pinned standalone binaries for them:

- `swiftlint lint` — SwiftLint 0.63.3, config in `.swiftlint.yml`. CI gates on
  error-level violations only (no `--strict`); warnings are advisory. Caveat: the
  standalone Linux binary runs without SourceKit, so SourceKit-backed rules
  (`custom_rules`, `statement_position`, `vertical_whitespace_*_braces`, etc.)
  are **skipped** and print a "requires SourceKit" warning. CI's official
  `ghcr.io/realm/swiftlint` Docker image bundles SourceKit and does run them, so
  a clean local `swiftlint lint` is necessary but not fully sufficient for those
  rules — the macOS build is the real check.
- `actionlint` — actionlint 1.7.12 with `shellcheck` for the `run:` blocks; lints
  `.github/workflows/*`.

Both are on `PATH` at `/usr/local/bin`. Run them from the repo root. Everything
else about building/running the product still requires an Apple host.
