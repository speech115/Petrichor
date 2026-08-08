# 01 — Now Playing по образцу Apple Music

**What to build:** Плеер переписан заново в `iOS/Player/`, старая реализация
удалена из `iOS/ContentView.swift`.

Причина белых полос сверху и снизу: градиент рисовался внутри контентной
области `NavigationStack`, safe area оставалась залита системным фоном.
Навигационной панели в новом экране нет вообще — грабер закрывает по тапу,
свайп вниз по отпусканию, меню трека рядом с названием.

Файлы: `NowPlayingScreen`, `PlayerPalette` (цвета из доминирующих цветов
обложки с зажатой яркостью — экран тёмный при любой обложке и теме),
`PlayerScrubber` (полоса без ручки, растёт под пальцем), `PlayerTransport`
(голые глифы, шаффл и повтор по краям чипами).

У слайдера громкости скрыта ручка (`setVolumeThumbImage` пустой картинкой) —
в Apple Music видна только полоса.

Заодно снят `matchedGeometryEffect` с обложки: и мини-плеер, и большая обложка
стояли `isSource: false`, то есть источника не было ни одного.

Спека: `.scratch/player-and-sources/spec.md`, раздел «Now Playing».

**Blocked by:** None

**Status:** done

- [x] Нет белых полос, фон под статус-баром и home indicator
- [x] Экран тёмный при светлой обложке и в светлой теме
- [x] Скраббер и громкость без ручек
- [x] Очередь и текст поднимаются панелями поверх обложки

## Comments

### 2026-08-09 — performance follow-up

Presentation baseline уточнён коммитом `8a53d44`: открытие, закрытие и
интерактивный drag управляются одним `NowPlayingPresentationLayer`; внутренний
экран не должен добавлять собственный removal-transition. Причина и покадровая
проверка записаны в `.scratch/playlist-perf/issues/13-now-playing-unified-transition.md`.
