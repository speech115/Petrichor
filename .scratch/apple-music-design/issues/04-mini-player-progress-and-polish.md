# 04 — Мини-плеер: линия прогресса + полиш

**What to build:** Compact-строка мини-плеера получает тонкую
**неинтерактивную линию прогресса** под строкой (как Apple Music). Expanded /
Now Playing — полноценный скраббер, без изменений; Now Playing остаётся
in-hierarchy оверлётом (`801ff25`).

Сюда же вплетается отложенный полиш мини-плеера: **свайп-вниз** (сворачивание)
и **morph обложки** мини-плеера в Now Playing — преемник отменённого
zoom-перехода (`02-now-playing-zoom-from-artwork`, подход заменён на
in-hierarchy оверлей). Один компонент трогаем один раз.

Спека: `.scratch/apple-music-design/spec.md`, раздел «Мини-плеер».

**Blocked by:** None — can start immediately.

**Status:** done

- [ ] Тонкая неинтерактивная линия прогресса в compact
- [ ] Свайп-вниз сворачивает Now Playing
- [ ] Morph обложки мини-плеера → Now Playing
- [ ] Обе платформы собираются
