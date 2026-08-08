# 09 — Now Playing: градиент, громкость, AirPlay, сжатие обложки

**What to build:** Экран Now Playing (`iOS/ContentView.swift`,
`nowPlayingCover` / `nowPlayingContent`) **не переделывается** — оверлей вместо
модалки, свайп вниз и morph обложки из мини-плеера остаются как есть. Четыре
добавления:

1. **Фон-градиент из цвета обложки** вместо `.ultraThinMaterial`. Цвет —
   `NowPlayingArtwork.tint(for:)`, вертикальный градиент к фону экрана. Уважать
   `useArtworkColors`.
2. **Слайдер громкости** под транспортом. Системный `AVRoutePickerView`-сосед —
   брать `MPVolumeView` или `AVAudioSession.outputVolume` с записью через
   системный слайдер; **не** изобретать свой контрол громкости, иначе аппаратные
   кнопки и слайдер разойдутся.
3. **AirPlay** между «Текстом» и «Очередью» — три кнопки в нижнем ряду вместо
   двух. Использовать `AVRoutePickerView` через `UIViewRepresentable`.
4. **Обложка сжимается до 0.86 на паузе.** Единственная обратная связь о
   состоянии, которую видно, не глядя на кнопку. Пружина, не линейная
   интерполяция; уважать `accessibilityReduceMotion`.

Осторожно с производительностью: `setFineProgressSampling(true)` включается на
этом экране, лишние перерисовки от градиента нежелательны — цвет считать один
раз на смену трека, а не в `body`.

Спека: `.scratch/two-tab-layout/spec.md`, раздел «Now Playing».

**Blocked by:** 07 — переиспользует ту же подкраску по обложке.

**Status:** ready-for-agent

## Проверка

Устройство (скилл `.agents/skills/petrichor-device/`): громкость двигается
вместе с аппаратными кнопками, AirPlay видит колонки, обложка сжимается на паузе
без рывка, свайп вниз по-прежнему закрывает экран мгновенно.

## Comments

### 2026-08-09 — актуальный presentation baseline

Перед реализацией этой полировки сохранить единый
`NowPlayingPresentationLayer` из `8a53d44`: фон, artwork и controls композятся и
двигаются вместе, а drag-offset принадлежит родителю. Не добавлять вложенный
`.transition(.move)` или отдельный offset обложки. Детали:
`.scratch/playlist-perf/issues/13-now-playing-unified-transition.md`.
