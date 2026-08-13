# Petrichor iOS — music-motion

Дата: 2026-08-13  
Статус: **в работе**  
Ресерч: `.scratch/apple-music-animations/spec.md`  
Grilling: подтверждено 2026-08-13

## Зачем

Сделать ключевые переходы «как Apple Music»: zoom открытия
плейлиста/альбома, color-matched detail, мелкий motion polish, и
измеренный spike для mini→Now Playing zoom.

## Скоуп (зафиксировано grilling)

**Внутри**
1. Zoom open плейлист/альбом (включая строки списка)
2. Full-bleed color-matched detail (как Music 26.4), уважает `useArtworkColors`
3. Press-подсветка строк трека
4. Swipe-up по mini-player → Now Playing
5. Свайп по названию = prev/next (mini + NP)
6. Glass/zoom на вторичных sheets (Track Info / toolbar) — не Now Playing
7. Spike mini→NP zoom; замена overlay только если latency ≤ baseline ±10%,
   dismiss/pinch живой, Reduce Motion ок

**Вне**
- Artist zoom / iOS 27 artist blend / landscape NP
- Pause-scale обложки, animated Lock Screen art
- Сетка плейлистов (остаёмся на списке)
- Анимации поиска, stagger Home, numericText на времени

## Порядок

01 zoom → 02 color page → 03–06 polish → 07 spike

## Проверка

Симулятор + замер для spike; устройство для feel, если доступно.
Автотесты только на существующих швах — SwiftUI transitions тестами не кроем.
