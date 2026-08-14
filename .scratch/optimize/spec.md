# Спека: thermos-ревью всего iOS-таргета

Дата: 2026-08-14. **Статус: active.**

Thermos-ревью на ветке `optimize/ios` (охват «`iOS/` целиком + iOS-швы в общих
слоях») дало 17 code-quality + 10 bug-находок. После дедупликации — 22 тикета.

## Вердикт

Кодовая база здорова: пять швов хорошо задокументированы, правило
«относительный путь в БД» соблюдается везде, observer/KVO-жизненный цикл
`AVQueuePlayerBackend` и cursor-семантика журнала чистые. Два кластера проблем:

1. **Рантайм-баги** — аудиосессия (interruption/route-change без main-hop,
   нет re-activate после прерывания, безусловный resume) и три гонки
   (Spotlight reset, фоновое сохранение на main, reentrancy скана).
2. **Нарушения канона** — `#if os` вне пяти швов (`Folder`, `AppAppearance`,
   `AppCoordinator`, `ImageUtils`) и залезание iOS-кода в `Views/` (macOS-only).

## Тикеты

| № | Тикет | Severity | Blocked by |
|---|---|---|---|
| 01 | headerTint: убрать зависимость от `Views/` и свести три копии | high | — |
| 02 | Bookmark-политика из `Folder` — в шов `LibraryPathStore` | high | — |
| 03 | `ColorMode.apply()` — платформенное тело за шов | high | — |
| 04 | `AppCoordinator`: `PlaybackJournal.make()` + шов для iOS reconcile | high | — |
| 05 | `ImageUtils`: `#if os` — в `PlatformShims` | high | — |
| 06 | Аудиосессия: main-hop + re-activate + `wasPlaying` | high | — |
| 07 | Spotlight: гонка reset против in-flight sync | med | — |
| 08 | Фоновое сохранение: encode+flush с main | med | — |
| 09 | `scanLibraryRoot`: reentrancy-guard | med | — |
| 10 | `trackNumberInfo`: ID3v2.3 TRCK читается как бинарь | med | — |
| 11 | `SpotlightIndexer`: три копии sync-алгоритма — в одну | med | — |
| 12 | `play/playAll/shuffleAll` ×4 — общий хелпер | med | — |
| 13 | «N songs» ×7 — общий форматтер | med | — |
| 14 | `albumEntity` lookup + destination ×3 | med | — |
| 15 | Playlist-artwork fallback ×2 — общая вью | med | — |
| 16 | `NowPlayingScreen`: вынести volume slider + AirPlay | med | — |
| 17 | `ContentView`: мёртвый enum + `MiniPlayerAccessory` | med | — |
| 18 | `PlaybackState`: относительный путь вместо абсолютного | low | — |
| 19 | UI: показывать/копировать относительный путь | low | — |
| 20 | Магические cache-key строки — в один билдер | low | — |
| 21 | Двойной schedule Spotlight + вынести mtime-tolerance | low | — |
| 22 | Filename-fallback: поднять правило в общий слой | low | — |

## Вне рамок

- Тесты вне швов из `AGENTS.md`.
- Рефакторинг `Views/` (macOS) — за рамками iOS-таргета.
- Новые `#if os` где бы то ни было вне существующих швов.
