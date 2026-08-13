# 03 — Automation вон из iOS-таргета, метаданные на `load()`

Status: resolved

## Проблема

Замер `SWIFT_STRICT_CONCURRENCY=complete` на схеме `PetrichoriOS` даёт ~700
предупреждений. Из них две группы — не настоящий долг изоляции:

1. **~194** — статические свойства AppIntents (`title`, `openAppWhenRun`,
   `description`, `typeDisplayRepresentation`, `defaultQuery`) из
   `Managers/Automation/`. Этот код компилируется в iOS-бинарник и на
   телефоне **ничего не делает**: `AppShortcutsProvider` для iOS не заведён.
   Мёртвый код + треть всех предупреждений.
2. **~180** — deprecation: `AVMetadataItem.value` (120), `.dataValue` (40),
   `.numberValue` (20) устарели с iOS 16 в пользу `load(.value)` и т.п.
   `iOS/AVAssetMetadataReader.swift` читает теги синхронным блокирующим API —
   это ещё и перформанс-хотспот (путь «тап→звук»).

## Что сделать

**1. Исключить `Managers/Automation` из iOS-таргета.** Механика уже есть:
exception set `55A000000000000000000011` в `Petrichor.xcodeproj/project.pbxproj`
(сейчас исключает `MenuBarManager.swift` из `PetrichoriOS`). Добавить в его
`membershipExceptions` все семь файлов: `Automation/AMContent.swift`,
`Automation/AMQuery.swift`, `Automation/AMTransport.swift`,
`Automation/AutomationEntities.swift`, `Automation/AutomationIntents.swift`,
`Automation/AutomationManager.swift`, `Automation/AutomationShortcuts.swift`.
Проверено заранее: ссылок на эти типы извне папки нет
(`grep -rn 'AutomationManager\|AutomationIntents' --include='*.swift' . | grep -v Managers/Automation`
— пусто); `Managers/RemoteCommandManager.swift` — отдельный файл, его не
трогать. macOS-таргет продолжает собирать Automation как раньше.

**2. Перевести `iOS/AVAssetMetadataReader.swift` на async-загрузку**:
`item.value` → `try await item.load(.value)`, аналогично `.dataValue`,
`.numberValue`, `.stringValue` если встретится. Сигнатуры шва не ломать без
нужды: `MetadataEngine` (`Core/Metadata/MetadataEngine.swift`) — проверить,
асинхронен ли протокол уже; если нет — асинхронизировать протокол и оба
адаптера (`CrescendoMetadataReader` на маке станет async-обёрткой над своим
синхронным чтением). Слоёв совместимости не оставлять.

## Критерии приёмки

- [x] `xcodebuild -scheme PetrichoriOS ... build SWIFT_STRICT_CONCURRENCY=complete 2>&1 | grep -c warning:`
      упало с ~700 до ~390 или ниже; число записать в Comments.
- [x] В обычной сборке iOS предупреждений по-прежнему ноль.
- [x] Обе схемы (`PetrichoriOS`, `Petrichor`) собираются.
- [x] `xcodebuild test -scheme PetrichoriOS` зелёный, включая
      `MetadataMappingTests` (тест шва метаданных).
- [x] В iOS-бинарнике нет символов Automation (проверить, например,
      `nm`/`strings` по собранному бинарнику или просто отсутствием файлов в
      build log).

## Comments

- 2026-08-13: влито (PR #3). Seam-тест AVAssetMetadataReader — PR #8.
