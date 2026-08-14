# 07 — Spike: mini → Now Playing zoom

**Status:** adopted  
**Blocked by:** 06

Порог grilling: latency ≤ baseline ±10% → замена overlay; иначе отчёт.

## Measurement (2026-08-13)

Системный `fullScreenCover` + `.navigationTransition(.zoom)` с
`matchedTransitionSource` на mini-player accessory, iPhone 17 Pro Max симулятор:

| Путь | tap → `NowPlayingScreen.onAppear` |
|---|---|
| Zoom | **212 ms** |
| Slide overlay | **120 ms** |

Zoom хуже baseline на ~77% — формальный порог не проходит.

## Decision (2026-08-13, late)

**Берём zoom.** Overlay оставался «просто выездом снизу» и не читался как Music;
после деплоя на устройство пользователь явно сказал, что прикольной анимации
нет ни у плеера, ни у плейлистов. Feel важнее ~90 ms.

Код: `ContentView` — `fullScreenCover` + zoom; закрытие — системный zoom gesture.

## Comments

### 2026-08-13 — local Mac

Замер выполнен; сначала отказ по порогу. Поздний фидбек → adopt.

### 2026-08-14 — interactive dismiss + artist pop-in

Два дефекта после перехода на zoom, оба закрыты:

1. **Непрерывность.** Custom `dismissGesture` на `NowPlayingScreen` оставался
   прикреплённым и съедал pan у системного интерактивного zoom — жест
   «срабатывал только после конца анимации». Путь custom drag dismiss удалён
   целиком (`presentationDragOffset`, `usesCustomDragDismiss`, `dismissGesture`):
   под zoom он мёртв, а присутствие `DragGesture` на контенте голодает системный
   жест. Теперь презентацию можно схватить на полпути и потянуть вниз.

2. **Артист с задержкой.** При сворачивании мини-плеера имя исполнителя
   появлялось на кадр позже названия: два `Text` — два display-list узла, и
   restore источника zoom ре-регистрировал их отдельными проходами.
   `.drawingGroup()` на title/artist VStack склеивает их в один слой — строка
   приезжает атомарно.
