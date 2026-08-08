---
name: ios-simulator
description: Build, launch, inspect and drive the PetrichoriOS app in the iOS Simulator with the repository-configured xcodebuildmcp MCP server — "проверь на симуляторе", "run it on the simulator", "погоняй флоу", "сделай скриншот", semantic UI automation (tap/gesture via elementRef), focused test runs, runtime logs. Use for everything a physical device cannot answer cheaply; the real iPhone is petrichor-device's job (playback, background audio, lock screen, DDI-free deploy).
---

# PetrichoriOS on the simulator

Build, launch, inspect and drive the app in the iOS Simulator through the
`xcodebuildmcp` MCP server pinned in `opencode.json`. Prefer its tools over
raw `xcodebuild`, `xcrun` or `simctl` when they are available. SwiftUI-вьюхи
не покрываются тестами — их проверка это симулятор и устройство; этот скилл
закрывает симуляторную половину.

## What this is not

Физический iPhone, фоновое аудио, локскрин, развёртывание без DDI — это
`.claude/skills/petrichor-device/`. Там же факты про телефон. Симулятор
отвечает на вопросы состояния и флоу, устройство — на вопросы окружения.

## Before you start

Работает на macOS 26.6, Xcode 26.6, Node 26. MCP-сервер сконфигурирован
в проекте для всех клиентов — один и тот же
`/Users/sereja/.npm-global/bin/xcodebuildmcp mcp` (глобальная установка
2.7.0, не `npx` — npx-старт отваливался по таймаутам health-пробы):

| Клиент | Конфиг |
|---|---|
| opencode | `opencode.json` → `mcp.xcodebuildmcp` |
| Claude Code | `.mcp.json` → `mcpServers.xcodebuildmcp` |
| Codex | `.codex/config.toml` → `mcp_servers.xcodebuildmcp` |
| Cursor | `.cursor/mcp.json` → `mcpServers.xcodebuildmcp` |

- `.xcodebuildmcp/config.yaml` → workflows `simulator`, `ui-automation`,
  `doctor` и session defaults (схема, симулятор, Debug). Единый источник
  для всех клиентов, не дублируется в конфигах.

Если инструментов нет в сессии: MCP-серверы читаются при старте клиента —
перезапусти клиент, не пытайся чинить на лету. Первый запуск может
потребовать trust/approve сервера. Если сервер стартует, но UI-инструментов
нет — проверь, что `.xcodebuildmcp/config.yaml` не отвёрстан и workflows
включены, потом снова перезапуск. Fallback на голые `xcodebuild`/`simctl` —
только когда MCP недоступен совсем.

## One simulator context

1. `session_show_defaults` — подтверди, что в defaults правильный
   project/scheme/simulator (они уже посеяны в config.yaml).
2. `list_sims` — выбери один явный UDID. Предпочитай уже загруженный
   симулятор; `boot_sim` — только если надо, никогда не создавай и не качай
   рантаймы без спроса.
3. `session_set_defaults` — если defaults неверные, поправь их под нашу
   схему и закрепи на выбранный UDID.
4. Держи все дальнейшие вызовы на том же UDID.

Не используй мак-автоматизацию окон, чтобы переключать Simulator. Явная
идентификация устройства надёжнее.

## Build or launch

- `build_run_sim` — когда менялись нативный код, зависимости, entitlements
  или конфигурация проекта.
- `test_sim` — для наименьшего релевантного тест-таргета или набора
  тестов; не гоняй всю матрицу по умолчанию. Наши тесты живут только на
  швах: `PetrichoriOSTests` (резолв пути, M3U, метаданные, сборка
  библиотеки) и `PetrichoriOSUITests`.
- `launch_app_sim` — когда приложение уже установлено и пересборка не
  нужна; рантайм-логи захватываются автоматически.
- Чтобы переиспользовать собранный артефакт: `get_sim_app_path` →
  `install_app_sim` при необходимости → `launch_app_sim`.
- Не запускай build-only перед `build_run_sim`, если нужен только
  второй.

После запуска сначала `snapshot_ui` или `screenshot` — открытое окно
Simulator само по себе не доказательство, что приложение запустилось.

## Drive the UI semantically

1. `snapshot_ui` — получить актуальное accessibility-дерево с
   `elementRef`.
2. Тапай только по текущим `elementRef`, у которых снапшот показывает
   намеренное действие. XcodeBuildMCP 2.7.0 не принимает координаты для
   `tap`; если у элемента нет пригодного ref — доложи accessibility-блокер,
   не переходи на десктопную автоматизацию.
3. После навигации или изменения лэйаута обновляй снапшот — elementRef
   живут в рамках одного снапшота.
4. Для асинхронных переходов используй `wait_for_ui` вместо фиксированных
   sleep.
5. Жесты — `gesture`, `swipe`; ненадёжный жест — вернись к известному
   роуту или перезапусти приложение, а не городи мак-автоматизацию.
6. Завершай флоу финальным `screenshot` — он и есть доказательство.

## Logs and debugging

- Рантайм-логи приходят из `launch_app_sim`; собирай только нужное по
  bundle id, не лей безразмерные логи в ответ — суммируй ошибки.
- LLDB-отладка (`debugging` workflow) в проекте не включена намеренно:
  на симуляторе она не нужна, на устройстве недоступна (нет DDI, см.
  petrichor-device). Диагностируй по напечатанному состоянию и логам.

## Clean up

Останавливай только то, что начато для текущей проверки: `stop_app_sim`,
захваченные логи. Не трогай ранее загруженные симуляторы и чужие сессии.

## Facts worth not re-deriving

| | |
|---|---|
| Scheme | `PetrichoriOS` |
| Bundle id | `org.Petrichor.ios` |
| Product | `Petrichor.app` |
| Project | `Petrichor.xcodeproj` (workspace нет) |
| Simulator | `iPhone 17 Pro Max`, уже загружен |
| Конфигурация | Debug |
| Тест-таргеты | `PetrichoriOSTests`, `PetrichoriOSUITests` |
| MCP-конфиг | `opencode.json` + `.xcodebuildmcp/config.yaml` |

## Upstream

Адаптировано из `pingdotgg/t3code/.agents/skills/ios-debugger-agent`
(MIT, форк OpenAI build-ios-apps), выровнено под XcodeBuildMCP 2.7.0 —
имена инструментов: `build_run_sim`, `test_sim`, `launch_app_sim`,
`snapshot_ui`, `tap`, `wait_for_ui`, `gesture`, `swipe`, `screenshot`.
