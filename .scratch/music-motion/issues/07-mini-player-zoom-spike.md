# 07 — Spike: mini → Now Playing zoom

**Status:** resolved  
**Blocked by:** 06

Порог: latency ≤ baseline ±10% → замена overlay; иначе отчёт и slide остаётся.

## Answer

**Не берём.** Системный `fullScreenCover` + `.navigationTransition(.zoom)` с
`matchedTransitionSource` на mini-player accessory измерен на iPhone 17 Pro Max
симуляторе (2026-08-13):

| Путь | tap → `NowPlayingScreen.onAppear` |
|---|---|
| Zoom spike | **212 ms** |
| Текущий slide overlay | **120 ms** |

Zoom хуже baseline на ~77% (порог был ±10%). Overlay остаётся. Spike-код
удалён после замера — мёртвый dual-path не оставляем.

Старый отказ (~0,48 с) из `playlist-perf/13` на этом SDK уже не воспроизводится
как 480 ms, но и 212 ms всё равно не проходит порог относительно текущего
overlay.

## Comments

### 2026-08-13 — cloud agent

На Linux cloud VM нет `xcodebuild` / симулятора — замер невозможен.
01–06 реализованы; `NowPlayingPresentationLayer` не трогаем до цифр на Mac.

### 2026-08-13 — local Mac

Замер выполнен; решение — не заменять. См. Answer.
