# 13 — Единая интерактивная анимация Now Playing

Status: resolved
Blocked by: 12

## Проблема

На первом открытии artwork мог оказаться на финальной позиции раньше остального
плеера. При свайпе вниз движение визуально дублировалось: внутренний content
следовал за локальным `dragOffset`, а после отпускания родительский
`.transition(.move)` второй раз двигал весь экран. Фон, обложка и controls
оказывались в разных фазах. Это баг presentation-кода приложения, не SwiftUI и
не сторонней библиотеки.

## Реализация

- `NowPlayingPresentationLayer` в `iOS/ContentView.swift` стал единственным
  владельцем mount/unmount, `offset`, `opacity` и интерактивного drag.
- Экран сначала монтируется вне viewport без анимации, ждёт один run-loop turn,
  затем весь `compositingGroup` поднимается одним transition.
- `NowPlayingScreen` пишет drag-offset в binding родителя. После порога dismiss
  продолжается с текущего положения пальца, без второго removal-transition.
- Фон, artwork и controls движутся одним слоем. Reduce Motion использует только
  opacity; grabber стал настоящей доступной кнопкой Close.

## Проверка

- Simulator build/run прошёл.
- Открытие и свайп вниз записаны и проверены покадрово: раннего artwork и
  второго движения после отпускания нет.
- Сборка установлена и запущена на iPhone через device workflow без тапов по
  физическому экрану; процесс Petrichor подтверждён.

## Comments

### 2026-08-09 — финальный animation follow-up

- Codex-задача: `019fe2c2-23fb-7af3-a399-77d4ded072a2`.
- Commit: `8a53d44 fix(ios): unify now playing presentation animation`.
- Commit отправлен в `origin/ios-port`.
- Пользователь отдельно попросил не управлять физическим iPhone. Следующие
  агенты по умолчанию проверяют UI в симуляторе; устройство — install/launch и
  read-only process/log checks, если нет новой явной просьбы.
