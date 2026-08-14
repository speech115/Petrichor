# 21 — Двойной schedule Spotlight + вынести mtime-tolerance

**Status:** ready-for-agent
**Blocked by:** —

`iOS/LibraryReconciliation.swift:55,89` оба зовут `SpotlightIndexer.scheduleSync`
(дедуп документирован в `SpotlightIndexer`, так что безопасно — но двойная точка
входа пахнет). Толеранс `> 1.0` mtime на `:125` переобъявляет ту же
clock-jitter-толеранс, что и `libraryContentsDiffer` («Same tolerance as…») — та
же магическая константа живёт в двух местах.

## Направление

Вынести константу толеранса; по возможности оставить одну точку schedule.
