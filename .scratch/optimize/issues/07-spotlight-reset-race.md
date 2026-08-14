# 07 — Spotlight: гонка reset против in-flight sync

**Status:** ready-for-agent
**Blocked by:** —

`iOS/SpotlightIndexer.swift:178-190` `resetIndex` намеренно обходит `isSyncing`,
но заканчивает вызовом `syncAfterReconciliation`, который уже гейтится. Если sync
в полёте, когда приходит `.libraryDataDidReset`: reset стирает индекс+snapshot,
свой resync рано возвращается, а in-flight sync (его `current`-чтения старше
стирания) переиндексирует до-reset строки и пишет до-reset snapshot. Stale-снапшот
живёт до следующего запуска — ровно то, что комментарий «wipe first» обещал не
допускать.

## Направление

Флаг `resetPending`, который `syncAfterReconciliation` перегоняет повторно после
завершения in-flight прохода (или счётчик поколений reset, прерывающий текущий
проход).
