# Тестирование iOS-приложения ИИ-агентом: лучший способ в 2026

Дата: 2026-08-08
Статус: проверено по первоисточникам

Вопрос: как тестировать iOS-приложение, когда тестировщик — ИИ-агент
(автоматизация UI, которую агент водит семантически: читать состояние
экрана, тапать по элементам, проверять результат). Проект PetrichoriOS:
SwiftUI, iOS 26, Xcode 26.6, агент в opencode с MCP-сервером
`xcodebuildmcp` (build_run_sim / snapshot_ui / tap / wait_for_ui /
gesture / screenshot; снапшоты — accessibility-дерево с elementRef,
тап по ref, а не по координатам).

## TL;DR

**Подход, который уже стоит в проекте — «snapshot accessibility-дерева →
tap по elementRef → wait_for_ui → screenshot как доказательство» — лучший
из доступных.** Он подтверждается тремя независимыми линиями доказательств:

1. **Бенчмарки LLM-агентов на iOS**: единственный интерактивный
   iOS-бенчмарк iOSWorld (CMU, 2026) измеряет разрыв «vision-only против
   vision + accessibility tree»: сильнейшие модели поднимаются с 20–29% до
   51.9% (улучшение до +26 п.п.), и ~70% провалов vision-only — ошибки
   локализации элементов, а не рассуждения ([iOSWorld](https://iosworld.io/)).
   То есть семантический доступ к дереву — не вкусовщина, а главный фактор
   успеха агента.
2. **Что выбирают те, кто уже гоняет агентов по iOS**: OpenAI (skill
   `build-ios-apps` завязан на XcodeBuildMCP: «prefer stable labels or
   element IDs instead of guessing raw screen positions»), Automattic
   (`simulator-llm-pilot` — runner поверх WebDriverAgent с
   `get_accessibility_tree`/`tap_element`), и десятки MCP-серверов
   (ios-simulator-mcp, simpilot, ios-agent-driver) — все сходятся на
   цикле «дерево → тап по элементу → перечитать дерево».
3. **Инженерная механика**: единственная альтернатива с той же
   семантикой — WebDriverAgent, но она добавляет HTTP-прокси и даёт
   снапшоты на порядок дороже («time-expensive operation», официальный
   troubleshooting Appium). idb даёт дерево, но тапает по координатам и
   почти не поддерживается Meta. XCUITest — единственный публичный API,
   но в живом режиме агент его не использует (тесты компилируются пачкой;
   тот же API внутри XcodeBuildMCP/AXe — приватный). Maestro — YAML-флоу
   на CI, а не живой вожж.

Рекомендация: **остаться на XcodeBuildMCP 2.6.x с AXe**, добавить
`accessibilityIdentifier` на нестабильные элементы (кнопки-иконки,
локальные лейблы), тестовый launch-аргумент для отключения анимаций,
использовать `wait_for_ui(settled)` вместо sleep. XCUITest-таргет оставить
только для узкого смоука на CI — не заменять им агентский цикл. Appium/WDA,
KIF, EarlGrey в проект не брать; idb/Maestro — только если понадобится
headless-прогон флоу без агента.

## Таблица сравнения инструментов

Критерии: **семантика** (может ли агент понять экран и тапать по элементу,
а не по координатам), **скорость** (снапшот/команда), **настройка**,
**надёжность тапов**, **агентность** (живой цикл «наблюдай → действуй →
проверяй» без пересборки).

| Инструмент | Семантика | Скорость | Настройка | Тапы | Агентность | Вердикт для агента |
|---|---|---|---|---|---|---|
| XCUITest/XCTest (Apple) | да (дерево, id/label) | снапшот ~сек, запуск теста дорогой (пересборка) | тест-таргет в проекте | `tap()` по hittable-точке — флаки внизу экрана, нужен forceTap | нет — пачка компилируемых тестов | только смоук на CI |
| XcodeBuildMCP + AXe (текущий стек) | да (elementRef = AXUniqueId, label) | бенчмарк проекта: −70% времени, −68% токенов vs старый цикл | уже настроена | по id/label через приватный AX + HID | да — живой цикл | **основной инструмент** |
| Appium + WebDriverAgent | да (W3C WebDriver, дерево, id/predicate) | снапшот — «time-expensive», тап ~1–2 с через HTTP-цепочку | тяжёлая: сборка WDA, Node-сервер, порты | по элементу, но через прокси; XPath медленный | частично (REST-команды), но медленно | не нужен: лишние слои |
| facebook/idb | частично: `ui describe-all` даёт дерево, но `ui tap X Y` — координаты | быстрые примитивы (нативные) | 2 компонента: companion (brew) + python-клиент; релизы Meta встали в 2022 | только координаты | да (CLI-примитивы), но без семантики тапа | fallback-примитив, не основа |
| Maestro (+ MCP) | да (дерево, text/id/point) | driver-раннер в симуляторе, дерево через XCTest-снапшот | средняя: Java 17+, driver на каждый симулятор | text/id regex → точка | MCP-сервер заточен под «напиши YAML и запусти», не под живой цикл | опция для зафиксированных E2E на CI, не для живого теста |
| KIF | да (accessibility) | быстрые (в процессе) | линковка в приложение | через событийную систему приложения | нет — нужен раннер | не подходит: белый ящик, приватные API |
| EarlGrey (2.x) | да (matchers по id) | быстрые, но launch XCUIApplication +6 с | тяжёлая: eDO, таргеты | в процессе, пиксель-видимость | нет — тесты, не живой вожж | не подходит: белый ящик |
| simctl (Xcode 26) | нет: нет синтеза ввода (см. ниже) | мгновенные (launch/install/screenshot) | встроен в Xcode | нет ввода вообще | — | только управление жизненным циклом |

## По инструментам

### XCUITest / XCTest (Apple)

Как работает: тест-раннер в отдельном процессе синтезирует события через
публичный API XCUIAutomation — запрос `XCUIElementQuery`, тап
`XCUIElement.tap()` («sends a tap event to a hittable point the system
computes for the element»), снимок дерева через `snapshot()` /
`debugDescription` ([Apple: User Interface Tests](https://developer.apple.com/documentation/xctest/user-interface-tests),
[Apple: XCUIElement](https://developer.apple.com/documentation/xcuiautomation/xcuielement),
[Apple: XCUICoordinate](https://developer.apple.com/documentation/xcuiautomation/xcuicoordinate)).

Плюсы: единственный публичный API Apple; поддерживается Xcode-инструментами
(Automation Explorer, Test Plans, xcodebuild, Xcode Cloud); чёрный ящик —
видит то же accessibility-дерево, что и пользователь VoiceOver.

Минусы для агента:

- Тесты компилируются в таргет и запускаются пачкой — живого цикла
  «посмотрел → решил → тапнул» нет; каждый прогон — пересборка и запуск
  раннера.
- `tap()` считает hittable-точку сам; для элементов внизу экрана, под
  home indicator, за popover-ом точка считается неверно — известные ошибки
  «Failed to synthesize event» / «Computed invalid hit point», обход — тап
  по координате центра через `coordinate(withNormalizedOffset:)` — то есть
  даже в XCUITest семантический тап не гарантирован
  ([SO: failed to synthesize event](https://stackoverflow.com/questions/62714744/xcuitest-failed-to-synthesize-event-failed-to-compute-hit-point-for-button),
  [SO: computed invalid hit point](https://stackoverflow.com/questions/40571744/xcode-ui-testing-failure-computed-invalid-hit-point),
  [Apple: tap()](https://developer.apple.com/documentation/xcuiautomation/xcuielement/tap())).
- XCUITest ждёт «idle» приложения (нет анимаций/работы главного потока) —
  на живых SwiftUI-экранах с бесконечными анимациями это вешает и тесты,
  и агентские команды поверх него; та же механика делает page source WDA
  дорогим (см. ниже).
- Элементы дерева ограничены глубиной 50 (макс 62) — глубже не видны
  ([Appium: Element Lookup Issues](https://appium.github.io/appium-xcuitest-driver/latest/troubleshooting/element-lookup/)).

Вердикт: для агента — нет; для проекта — узкий смоук-флоу на CI возможен,
но по AGENTS.md вьюхи тестами не покрываются, поэтому даже это — опция,
не рекомендация.

### XcodeBuildMCP + AXe (текущий стек проекта)

Как работает: XcodeBuildMCP оборачивает `xcodebuild`, `xcrun simctl`,
LLDB и CLI **AXe** в ~82 MCP-инструмента ([XcodeBuildMCP docs](https://www.xcodebuildmcp.com/docs)).
AXe — отдельный macOS-CLI (MIT, cameroncooke/AXe): тапает, свайпает,
печатает текст через **приватные Accessibility API + синтез HID-событий
в симулятор**, поддерживает Xcode 26 и 27 (на 27 — через Device Hub, окно
Simulator.app не требуется), тап по координатам, `--id` (AXUniqueId) или
`--label` ([AXe](https://github.com/cameroncooke/AXe),
[axe-cli.com/docs](https://www.axe-cli.com/docs)). XcodeBuildMCP передаёт
в AXe id/label, координаты — fallback ([tap.ts](https://github.com/getsentry/XcodeBuildMCP/blob/c40789b9/src/mcp/tools/ui-automation/tap.ts)).
С версии 2.6.0 UI-автоматизация отдаёт агенту «reusable context»: после
каждого действия — компактный снапшот с elementRef и screen hash;
`snapshot_ui` поддерживает `sinceScreenHash` (пропуск неизменившегося
экрана), `wait_for_ui` (предикаты existence/enabled/focus/text/settled),
`batch` (несколько тапов за один вызов), `drag` по ref; бенчмарк проекта:
~70% меньше wall-clock, 68% меньше токенов, 76% меньше вызовов
([CHANGELOG](https://github.com/getsentry/XcodeBuildMCP/blob/main/CHANGELOG.md),
[Output Formats](https://www.xcodebuildmcp.com/docs/output-formats)).

Плюсы: единственный стек в списке, где **тап семантический (по AXUniqueId),
снапшоты дешёвые (без idle-ожидания XCTest), живой цикл без пересборки**;
головаless-режим `XCODEBUILDMCP_HEADLESS_LAUNCH`; OpenAI выбрал этот
инструмент для своего skill `build-ios-apps` — «read the on-screen
accessibility hierarchy, take screenshots, tap controls... prefer stable
labels or element IDs instead of guessing raw screen positions»
([OpenAI skill](https://github.com/openai/plugins/blob/main/plugins/build-ios-apps/skills/ios-debugger-agent/SKILL.md),
[OpenAI: iOS simulator debugging](https://developers.openai.com/codex/use-cases/ios-simulator-bug-debugging)).

Минусы: AXe использует приватные API (ломаются при смене Xcode — за
проект отвечает чужая команда; на Xcode 27 уже перешли на Device Hub);
semver-гейты версий AXe; нет встроенной записи видео для отчёта (но есть
`record_sim_video`).

Вердикт: основной инструмент; подтверждён, остаётся.

### Appium + WebDriverAgent

Как работает: Appium server (Node) → XCUITest driver → WebDriverAgent —
Objective-C WebDriver-сервер, который живёт **внутри симулятора** как
`.xctrunner` и дергает XCTest API; команда проходит 5 слоёв
([Appium XCUITest driver: Overview](https://appium.github.io/appium-xcuitest-driver/11.17/overview/),
[Appium: Intro to Drivers](https://appium.io/docs/en/latest/intro/drivers/)).

Минусы для агента, зафиксированные в официальной документации Appium:

- «In order to retrieve the page source, WDA needs to take a snapshot of
  the whole accessibility hierarchy with all element attributes resolved,
  which is a time-expensive operation» — плюс XCTest-проверка idle-состояния
  приложения на каждой команде ([WDA Slowness](https://appium.github.io/appium-xcuitest-driver/latest/troubleshooting/wda-slowness/)).
- XPath-локаторы не нативные для XCTest — только через полный снапшот
  (там же); глубина дерева ≤ 62 ([Element Lookup](https://appium.github.io/appium-xcuitest-driver/latest/troubleshooting/element-lookup/)).
- Тап через всю цепочку — порядка 1–2 с на команду даже на ранних версиях
  ([WebDriverAgent issue #814](https://github.com/facebook/WebDriverAgent/issues/814)).
- Настройка тяжёлая: сборка WDA под конкретный Xcode, ключи, порты,
  управление процессом ([Manage WDA by Yourself](https://appium.github.io/appium-xcuitest-driver/latest/guides/wda-custom-server/)).

Плюс: W3C WebDriver — стандартный протокол, годится для device-фарм и
кросс-платформенных стеков; WDA видит WebView-контент глубже, чем idb
([pippin PLAN-wda-migration](https://github.com/acrollet/pippin/blob/main/PLAN-wda-migration.md)).

Вердикт: семантика та же, что у AXe, но медленнее и с лишними слоями.
Для локального агента не нужен. Заслуживает внимания только как движок
«резидентного раннера» в чужих инструментах (Automattic, simpilot,
tapflow) — см. раздел про LLM-подходы.

### facebook/idb

Как работает: «iOS Development Bridge» — companion-процесс на macOS
(FBSimulatorControl/FBDeviceControl, приватные фреймворки Xcode) + CLI
(`idb ui describe-all`, `idb ui tap X Y`, `idb ui text`, `idb ui
describe-point` — примитивы для симуляторов и устройств)
([facebook/idb](https://github.com/facebook/idb),
[idb commands](https://raw.githubusercontent.com/facebook/idb/refs/heads/main/website/docs/commands.mdx)).

Плюсы: быстрые нативные примитивы; единый интерфейс симулятор/устройство;
`describe-all` — готовое дерево; Maestro начинал на нём
([Maestro: Re-Building the iOS Driver](https://maestro.dev/blog/maestro-re-building-the-ios-driver)).

Минусы:

- Тап — только по координатам; семантики у idb нет.
- Два компонента (companion из исходников/brew + python-клиент) — хрупкая
  установка; релизы Meta остановились (последние — 2022), клиент фактически
  в режиме сопровождения: «fb-idb is archived/unmaintained by Meta»
  ([releases](https://github.com/facebook/idb/releases),
  [pippin](https://github.com/acrollet/pippin/blob/main/PLAN-wda-migration.md)).
- Не видит WebView-контент (там же).

Вердикт: не основа. На нём построен популярный `ios-simulator-mcp`
([joshuayoes/ios-simulator-mcp](https://github.com/joshuayoes/ios-simulator-mcp),
упомянут в best practices Anthropic) — но он даёт те же координатные тапы;
полезен как fallback-примитив (например, `ui describe-point` для «измерить,
не гадать»), что уже зафиксировано в практике одного из кейсов
([Teaching Claude to QA a Mobile App](https://christophermeiklejohn.com/ai/zabriskie/development/android/ios/2026/03/22/teaching-claude-to-qa-a-mobile-app.html)).

### Maestro

Как работает: чёрный ящик «at arm's length» — драйвер-приложение
(на iOS — резидентный XCUITest-раннер с HTTP-сервером, первоначально idb)
читает дерево и шлёт низкоуровневые тапы; тесты — декларативные YAML-флоу;
«zero-wait intelligence» — сам ждёт загрузки; MCP-сервер встроен в CLI
(`maestro mcp`): `list_devices`, `inspect_screen` (дерево как JSON), `run`
(YAML-флоу), `take_screenshot`
([How Maestro works](https://docs.maestro.dev/get-started/how-maestro-works),
[Maestro MCP](https://docs.maestro.dev/get-started/maestro-mcp),
[Maestro: iOS driver](https://maestro.dev/blog/maestro-re-building-the-ios-driver)).

Плюсы: флоу — детерминированный артефакт (versioned YAML, CI); селекторы
text/id regex по дереву; сам лечит флаки; MCP-сервер позиционирован именно
под агентов («write and run your mobile tests... it fixes what breaks as it
goes» — [maestro.dev/mcp](https://maestro.dev/mcp)).

Минусы: философия — «напиши флоу и запусти», а не живой семантический
вожж; дерево через XCTest-снапшот (та же дороговизна, что у WDA; есть
кейсы оптимизации дерева на 4x у RN-приложений — [blog](https://maestro.dev/blog/how-maestro-is-reinventing-mobile-test-automation));
Java 17+, driver надо ставить на каждый симулятор; для одного приложения
агент всё равно ходит инструментами XcodeBuildMCP быстрее.

Вердикт: не для живого теста агентом; разумная опция позже, если проекту
понадобятся зафиксированные E2E-флоу на CI без агента.

### KIF и EarlGrey

KIF: «Keep It Functional» — ин-процессная интеграция в приложение,
тесты через XCTest-таргет, драйв по accessibility-атрибутам, синхронный
main thread ([KIF](https://github.com/kif-framework/KIF)). EarlGrey (Google):
2.x — гибрид: out-of-process XCUITest + white-box RMI через eDistantObject,
автосинхронизация с UI/сетью, пиксельная проверка видимости; caveat:
«XCUITest application launches can add a 6+ second delay»
([EarlGrey](https://github.com/google/EarlGrey),
[EarlGrey FAQ](https://github.com/google/EarlGrey/blob/master/docs/faq.md),
[EarlGrey README 2.2.2](https://github.com/google/EarlGrey/blob/2.2.2/README.md)).

Плюсы: лучшая синхронизация и стабильность для написанных тестов.

Минусы для агента: белые ящики — требуют линковки в приложение (KIF —
приватные API, EarlGrey — eDO-мосты), тесты компилируются в таргет; оба
не дают живого «прочитай экран → тапни» интерфейса наружу; EarlGrey 1.0
deprecated.

Вердикт: не подходят. Причём не только агенту — они противоречат и
чёрно-ящичному подходу проекта.

### simctl (Xcode 26)

Факт, который стоит зафиксировать: **в simctl нет синтеза ввода**.
`simctl ui` умеет только appearance/content_size/интерфейсные настройки
([Xcode 11.4 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-11_4-release-notes)),
`simctl io` — только screenshot/recordVideo. Попытки обернуть `simctl io
tap` — известная ловушка: в одном MCP-сервере инструменты «shelled out to
simctl io <tap|swipe|...>, but simctl io has no input operations, so every
call was a no-op that errored» и были переписаны на синтез CGEvents по окну
Simulator ([toba/xc-mcp commit](https://github.com/toba/xc-mcp/commit/c4d07e75af7ddcc8572492c4696dd9e9b993fd8d)).

Роль simctl в нашем стеке — жизненный цикл (boot/install/launch/screenshot/
privacy), и здесь он незаменим и быстр. Менять не нужно.

## Что выбирают крупные ИИ-агентные подходы (и почему)

- **iOSWorld (CMU)** — первый интерактивный бенчмарк LLM-агентов на iOS:
  133 задачи, 26 приложений. Две модальности: vision-only и vision+XML
  (очищенное XCUITest-дерево ≤200 элементов, тап по accessibility id).
  Результат: лучшая конфигурация 51.9% против 20–29% у vision-only;
  «Privileged XML access improves the stronger frontier models by up to 26
  points»; ~70% провалов vision-only в single-app — ошибки навигации по
  домашнему экрану и локализации элементов; в памяти/мульти-апп задачах
  дерево даёт самое большое улучшение ([iOSWorld](https://iosworld.io/)).
  Вывод для нас: **дерево с id — не «удобство», а определяющий фактор
  успеха агента на iOS**; vision-only разумно держать только как fallback.
- **AppAgent / MobileAgent / MMBench-GUI**: AppAgent (XML-дерево с
  уникальными ID элементов) стабильно превосходит vision-only MobileAgent
  по всем метрикам; vision-локализация иконок/текста — слабое место
  ([AppAgent](https://arxiv.org/abs/2312.13771),
  [ACM AppAgent](https://dl.acm.org/doi/full/10.1145/3706598.3713600)).
  MMBench-GUI: «accurate visual grounding is a critical determinant of
  overall task success», и все модели страдают от неэффективности шагов —
  аргумент за компактные семантические снапшоты ([MMBench-GUI](https://github.com/open-compass/MMBench-GUI)).
  Это про Android, но вывод про дерево переносится.
- **OpenAI (build-ios-apps / Codex)**: официальный skill для iOS-разработки
  завязан именно на XcodeBuildMCP — «inspect the view tree before it taps...
  prefer stable labels or element IDs instead of guessing raw screen
  positions» ([OpenAI skill](https://github.com/openai/plugins/blob/main/plugins/build-ios-apps/skills/ios-debugger-agent/SKILL.md)).
- **Automattic (simulator-llm-pilot)**: продакшн-раннер LLM-тестов для
  WordPress-iOS в ночных CI: тесты на markdown, модель ходит строго через
  `get_accessibility_tree` / `tap_element` / `type_text` поверх WebDriverAgent;
  мотивация — «XCUITest-style UI tests are brittle... let the model adapt
  at runtime using the current accessibility tree», плюс песочница вместо
  прав супер-агента ([simulator-llm-pilot](https://github.com/Automattic/simulator-llm-pilot)).
  Живой пример: тест-ассерт переведён с «inferred implementation
  identifiers» на видимый контент — тот же урок, что ниже в рекомендациях
  ([WP PR #25847](https://github.com/wordpress-mobile/WordPress-iOS/pull/25847)).
- **Anthropic / Apple**: Apple встроила Claude Agent SDK в Xcode 26.3 с
  захватом SwiftUI-превью через MCP ([Anthropic](https://www.anthropic.com/news/apple-xcode-claude-agent-sdk)) —
  это про визуальную итерацию, не про рантайм-тест; рантайм-проверка в
  Xcode по-прежнему агентная задача, и Anthropic рекомендует MCP-серверы
  для симулятора в best practices ([Claude Code best practices](https://www.anthropic.com/engineering/claude-code-best-practices),
  [qckfx обзор стека](https://qckfx.com/blog/giving-your-ai-coding-agent-eyes-on-ios)).

Общая сходимость: **accessibility-дерево — первичное восприятие; скриншот —
вторичное (fallback и доказательство); координаты — только после
измерения через дерево**. Прямые цитаты: «Accessibility-tree-first
perception... tap by label, not by guessing pixel coordinates»
([ios-agent-driver](https://github.com/CodeJonesW/ios-agent-driver)),
«Map the UI first, tap second. Don't guess coordinates — measure them»
([Meiklejohn](https://christophermeiklejohn.com/ai/zabriskie/development/android/ios/2026/03/22/teaching-claude-to-qa-a-mobile-app.html)),
«Accessibility tree before screenshot vision. Receipts or it did not
happen» ([iosctl](https://github.com/danielgwilson/iosctl)).

## Apple-специфика Xcode 26 / iOS 26

- **Новая запись UI-тестов и Automation Explorer**: кодогенерация
  взаимодействий и постфактум-инспекция элементов с видео прогона —
  для человека-разработчика, но документирует, какие атрибуты видит
  автоматизация ([WWDC25: Record, replay, and review](https://developer.apple.com/videos/play/wwdc2025/344/),
  [Xcode 26 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)).
- **Подготовка приложения к автоматизации — официальная рекомендация
  Apple**: «add accessibility identifiers... need to be descriptive, static,
  and unique within the entire app», ревью через Accessibility Inspector
  (там же, WWDC25 session 344). Это ровно то, что улучшает и наш агентский
  цикл.
- **XCTHitchMetric** — метрика хича в UI-тестах; runtime issue detection и
  Runtime API Checks в Test Plans — полезны для CI, не для агента
  ([WWDC25: What's new in Xcode 26](https://developer.apple.com/videos/play/wwdc2025/247/)).
- **Headless**: `xcodebuild build-for-testing` + `test-without-building`
  работают без GUI; XCUITest-раннеры запускаются на `simctl boot`-симуляторе
  без окна — на этом стоят «резидентные раннеры» (Maestro, tapflow) и AXe;
  XcodeBuildMCP для Xcode 27 уже не требует Simulator.app ([AXe](https://github.com/cameroncooke/AXe),
  [tapflow](https://dev.to/joduchan/coordinate-based-ui-tests-break-so-we-read-the-accessibility-tree-instead-from-inside-the-3gl7)).
- **simctl**: ввода нет (см. выше); для жизненного цикла — работает.
- **XCUIScreen.synthesizeEvents** — принудительные тапы «through touch
  events» существуют, но живут внутри XCUITest-раннера; агенту напрямую
  недоступны ([Apple: XCUIScreen](https://developer.apple.com/documentation/xctest/xcuiscreen)).

## Вывод и рекомендация для PetrichoriOS

**Подход проекта подтверждается: остаёмся на «snapshot_ui (elementRef) →
tap → wait_for_ui → screenshot».**

Конкретные улучшения, в порядке ценности:

1. **accessibilityIdentifier на нестабильные элементы.** Apple: id должен
   быть «descriptive, static, and unique within the entire app» (WWDC25
   344). У нас лейблы динамичны (названия треков), кнопки-иконки без
   текста — им нужен стабильный id через `.accessibilityIdentifier(...)`.
   Но без перебора: назначать там, где снапшот уже показал неоднозначность
   (урок Automattic: ассертить видимый контент, а не выдуманные id —
   [PR #25847](https://github.com/wordpress-mobile/WordPress-iOS/pull/25847)).
2. **Тестовый launch-аргумент для анимаций.** `app.launchArguments` из
   Test Plan в приложение сами не пробрасываются — флаг читает приложение
   при старте ([Apple forums](https://developer.apple.com/forums/thread/759226)).
   Схема: `-UITestDisableAnimations` в `launchArgs` у `build_run_sim` /
   `launch_app_sim`, приложение на старте вызывает
   `UIView.setAnimationsEnabled(false)` и гасит явные SwiftUI-анимации.
   Стандартный приём ([simplified.guide](https://www.simplified.guide/xcuitest/animations-disable),
   [Jesse Squires](https://www.jessesquires.com/blog/2021/03/17/xcode-ui-testing-reliability-tips/)).
   Внимание: глушить всё подряд нельзя — анимации могут быть частью
   проверяемого поведения.
3. **wait_for_ui(settled) вместо sleep** — уже используется; закрепить в
   скилле как обязательный шаг после навигации.
4. **Дорогие снапшоты — по хешу.** `snapshot_ui` с `sinceScreenHash`
   пропускает неизменённый экран ([CHANGELOG](https://github.com/getsentry/XcodeBuildMCP/blob/main/CHANGELOG.md)) —
   экономит токены на длинных флоу.
5. **XCUITest-смоук на CI — опция, не замена.** Таргет `PetrichoriOSUITests`
   в схеме уже есть; если добавлять — только узкий смоук (запуск,
   библиотека, тап в трек), потому что (а) по AGENTS.md вьюхи тестами не
   покрываются, (б) агентский цикл быстрее и дешевле на неизвестных путях.
   Maestro туда же — только когда появятся зафиксированные флоу.
6. **Не делать:** Appium/WDA (медленные снапшоты, 5 слоёв), KIF/EarlGrey
   (белые ящики), idb как основа (координаты, сопровождение встало),
   координатные тапы без измерения через дерево (бенчмарки и практика —
   против). simctl — только жизненный цикл, как сейчас.
7. **Логи как сигнал верификации.** Рантайм-логи (`launch_app_sim`
   захватывает) + осмысленные `Logger`-сообщения в коде на ключевых путях
   дают агенту сигнал, который дерево не даёт (данные загрузились /
   застряли) ([Closing the loop on iOS](https://nadol.dev/blog/closing-the-loop-on-ios/)).
8. **Детерминизм через лаунч-состояние.** Моки на launch-аргументах
   (TestLaunchConfig-паттерн) — когда понадобится приземляться в конкретное
   состояние без прохода онбординга ([nadol.dev](https://nadol.dev/blog/closing-the-loop-on-ios/),
   [qckfx](https://qckfx.com/blog/giving-your-ai-coding-agent-eyes-on-ios)).
   Сейчас в приложении нет онбординга — не срочно.

## Источники

Apple:
- [Apple — User Interface Tests](https://developer.apple.com/documentation/xctest/user-interface-tests)
- [Apple — XCUIElement / tap() / XCUICoordinate / XCUIScreen](https://developer.apple.com/documentation/xcuiautomation)
- [Apple — Xcode 26 Release Notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)
- [WWDC25 — Record, replay, and review: UI automation with Xcode](https://developer.apple.com/videos/play/wwdc2025/344/)
- [WWDC25 — What's new in Xcode 26](https://developer.apple.com/videos/play/wwdc2025/247/)
- [Apple Forums — Test Plans launch args не пробрасываются в приложение](https://developer.apple.com/forums/thread/759226)
- [Xcode 11.4 Release Notes — simctl ui](https://developer.apple.com/documentation/xcode-release-notes/xcode-11_4-release-notes)

Инструменты:
- [getsentry/XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP), [docs](https://www.xcodebuildmcp.com/docs), [CHANGELOG](https://github.com/getsentry/XcodeBuildMCP/blob/main/CHANGELOG.md), [tap.ts](https://github.com/getsentry/XcodeBuildMCP/blob/c40789b9/src/mcp/tools/ui-automation/tap.ts)
- [cameroncooke/AXe](https://github.com/cameroncooke/AXe), [axe-cli.com](https://www.axe-cli.com/docs)
- [appium/WebDriverAgent](https://github.com/appium/WebDriverAgent)
- [Appium XCUITest driver — Overview](https://appium.github.io/appium-xcuitest-driver/11.17/overview/)
- [Appium — WDA Slowness](https://appium.github.io/appium-xcuitest-driver/latest/troubleshooting/wda-slowness/)
- [Appium — Element Lookup Issues](https://appium.github.io/appium-xcuitest-driver/latest/troubleshooting/element-lookup/)
- [facebook/idb](https://github.com/facebook/idb), [idb commands](https://fbidb.io/docs/commands), [releases](https://github.com/facebook/idb/releases)
- [mobile-dev-inc/Maestro](https://github.com/mobile-dev-inc/Maestro), [How Maestro works](https://docs.maestro.dev/get-started/how-maestro-works), [Maestro MCP](https://docs.maestro.dev/get-started/maestro-mcp), [Maestro — Re-Building the iOS Driver](https://maestro.dev/blog/maestro-re-building-the-ios-driver)
- [kif-framework/KIF](https://github.com/kif-framework/KIF)
- [google/EarlGrey](https://github.com/google/EarlGrey), [EarlGrey FAQ](https://github.com/google/EarlGrey/blob/master/docs/faq.md), [README 2.2.2](https://github.com/google/EarlGrey/blob/2.2.2/README.md)
- [joshuayoes/ios-simulator-mcp](https://github.com/joshuayoes/ios-simulator-mcp)
- [toba/xc-mcp — simctl io не имеет input-операций](https://github.com/toba/xc-mcp/commit/c4d07e75af7ddcc8572492c4696dd9e9b993fd8d)

Агентные подходы и бенчмарки:
- [iOSWorld](https://iosworld.io/) — первый интерактивный iOS-бенчмарк LLM-агентов
- [AppAgent (arXiv)](https://arxiv.org/abs/2312.13771), [ACM](https://dl.acm.org/doi/full/10.1145/3706598.3713600)
- [MMBench-GUI](https://github.com/open-compass/MMBench-GUI)
- [OpenAI — build-ios-apps skill](https://github.com/openai/plugins/blob/main/plugins/build-ios-apps/skills/ios-debugger-agent/SKILL.md), [Codex use-case](https://developers.openai.com/codex/use-cases/ios-simulator-bug-debugging)
- [Automattic/simulator-llm-pilot](https://github.com/Automattic/simulator-llm-pilot), [WordPress-iOS PR #25847](https://github.com/wordpress-mobile/WordPress-iOS/pull/25847)
- [Anthropic — Claude Agent SDK в Xcode 26.3](https://www.anthropic.com/news/apple-xcode-claude-agent-sdk)
- [CodeJonesW/ios-agent-driver](https://github.com/CodeJonesW/ios-agent-driver), [danielgwilson/iosctl](https://github.com/danielgwilson/iosctl), [passerby2049/simpilot](https://github.com/passerby2049/simpilot)
- [qckfx — verification gap](https://qckfx.com/blog/giving-your-ai-coding-agent-eyes-on-ios)
- [nadol.dev — Closing the loop on iOS](https://nadol.dev/blog/closing-the-loop-on-ios/)
- [Christopher Meiklejohn — Teaching Claude to QA a Mobile App](https://christophermeiklejohn.com/ai/zabriskie/development/android/ios/2026/03/22/teaching-claude-to-qa-a-mobile-app.html)
- [tapflow — resident XCUITest runner для дерева](https://dev.to/joduchan/coordinate-based-ui-tests-break-so-we-read-the-accessibility-tree-instead-from-inside-the-3gl7)

Практика UI-тестов:
- [SO — Failed to synthesize event](https://stackoverflow.com/questions/62714744/xcuitest-failed-to-synthesize-event-failed-to-compute-hit-point-for-button)
- [SO — Computed invalid hit point](https://stackoverflow.com/questions/40571744/xcode-ui-testing-failure-computed-invalid-hit-point)
- [Jesse Squires — Xcode UI testing reliability tips](https://www.jessesquires.com/blog/2021/03/17/xcode-ui-testing-reliability-tips/)
- [simplified.guide — How to disable animations for XCUITest](https://www.simplified.guide/xcuitest/animations-disable)
