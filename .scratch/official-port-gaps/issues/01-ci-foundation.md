# 01 — CI-фундамент: фикстуры, рабочий smoke-тест, Release-джоба

Status: resolved

## Проблема

Единственный UI-тест `Tests/PetrichoriOSUITests/PlaybackSmokeUITests.swift`
требует mp3-файлов в `Documents` симулятора, засеянных **вручную** (см.
комментарий в его setUp) — в CI он пройти не может по существу. При этом
джоба `ios-test` в `.github/workflows/ci.yml` формально запускает
`xcodebuild test` по схеме `PetrichoriOS`. Release-сборка iOS не проверяется
нигде: джоба `release-build` собирает только macOS — Release-only поломки
(оптимизатор, выключенные assert'ы) всплывут при заливке на телефон.

## Что сделать

**1. Самозасев фикстур.** В репо уже есть генератор тихих mp3 с ID3-тегами:
`makeSilentMP3` (`Tests/PetrichoriOSTests/TestFixtures.swift:122`) — юнит-тесты
им пользуются, традиция «no binary fixtures» записана в его докстроке.
Бинарники в репозиторий **не** коммитить. Дать приложению DEBUG-only путь
самозасева:

- Вынести генератор туда, где его достанет app-таргет (например,
  `Utilities/` под `#if DEBUG`, либо отдельный файл с membership в обоих
  тест-таргетах и app-таргете — на усмотрение исполнителя, но без дублей кода).
- В `iOS/PetrichorApp.swift` (init, до создания `AppCoordinator` — его init
  запускает реконсиляцию): при launch-аргументе `--uitest-seed-fixtures`
  идемпотентно создать `Documents/Music/{Alpha One,Beta Two,Gamma Three}.mp3`.
  Имена — ровно те, что уже ждёт smoke-тест. Весь блок — под `#if DEBUG`.
- В smoke-тесте: `app.launchArguments += ["--uitest-seed-fixtures"]`, убрать
  из комментария инструкцию про ручной `simctl push`.

**2. Убедиться, что UI-тесты входят в test-action схемы `PetrichoriOS`**
(проверить схему; если таргет `PetrichoriOSUITests` не включён — включить).

**3. Release-джоба iOS.** В `.github/workflows/ci.yml` добавить джобу
`ios-release-build`: `workflow_dispatch` only, сборка
`-scheme PetrichoriOS -configuration Release` под iOS Simulator, с теми же
кэшами/секрет-заглушкой, что у `ios-test`, без подписи. Прогонять её перед
каждой заливкой на телефон (записано в скилле не будет — это ручной шаг).

## Критерии приёмки

- [x] Локально: чистый симулятор → `xcodebuild test -scheme PetrichoriOS ...`
      зелёный целиком, включая `PlaybackSmokeUITests`, без ручного засева.
- [x] В диффе нет ни одного бинарного файла.
- [x] Засев не срабатывает без launch-аргумента и не попадает в Release
      (`#if DEBUG`).
- [x] CI: джоба `ios-test` зелёная с UI-тестом в составе.
- [x] `workflow_dispatch` → `ios-release-build` зелёная.
- [ ] На устройстве (скилл `petrichor-device`): трек играет, локскрин
      заполнен — ручная проверка, результат в Comments.

## Comments

- 2026-08-13: влито (PR #2, CI runtime #9). Локскрин на устройстве — осознанная дыра, не закрыта.
