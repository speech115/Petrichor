# 04 — `AppCoordinator`: `PlaybackJournal.make()` + шов для iOS reconcile

**Status:** ready-for-agent
**Blocked by:** —

`Application/AppCoordinator.swift` ветвится в composition root:
- `:57-61` — `playbackJournal = JSONLPlaybackJournal()` vs `nil`: решение
  «nil (macOS) vs JSONL (iOS)» по `AGENTS.md` обязано жить в самом шве
  `PlaybackJournal`, а не в точке использования.
- `:65-83` — iOS-only `reconcileLibrary()` в startup `Task` без шва.

## Направление

`PlaybackJournal.make()` (static factory) на шве — AppCoordinator вызывает его
без `#if`. Для launch-reconciliation — именованный шов/extension point вместо
inline `#if`.
