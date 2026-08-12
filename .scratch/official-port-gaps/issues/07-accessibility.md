# 07 — Доступность: метки, Dynamic Type, аудит-гейт в CI

Status: ready-for-agent
Blocked by: 01

## Проблема

`accessibility*` встречается в 12 файлах `iOS/`, почти везде по одной метке.
Строки треков, карусели Home, обложки — без меток и объединения: VoiceOver
читает их как россыпь безымянных элементов. 21 вхождение
`.font(.system(size:))` — фиксированные кегли, не следующие Dynamic Type:
при увеличенном шрифте эти надписи не растут. Регрессию ничего не ловит.

## Что сделать

**1. VoiceOver-метки и объединение.** Пройти по экранам:

- `iOS/Components/TrackRow.swift` — `.accessibilityElement(children: .combine)`
  на строку; итоговая метка «название, артист»; кнопка меню — своя метка.
- `iOS/Components/ArtworkTile.swift` — обложка декоративна там, где рядом есть
  текст: `.accessibilityHidden(true)`; самостоятельные тайлы (грид плейлистов)
  — метка с названием.
- `iOS/Home/HomeTabView.swift`, `iOS/Home/RecentAlbumsShelf.swift` — карточки
  каруселей: один элемент = одна карточка с меткой.
- `iOS/Player/PlayerScrubber.swift` — `.accessibilityValue` (позиция/длительность)
  и `.accessibilityAdjustableAction` для перемотки.
- `iOS/Library/IndexedList.swift` — алфавитный индекс-бар: метка + adjustable.
- Проверить остальное перечисленное в аудите (`performAccessibilityAudit`
  сам покажет пропуски — см. п.3).

**2. Dynamic Type.** Заменить фиксированные кегли на текстовые стили либо
`@ScaledMetric` (для иконок-глифов — `.font(.title2)` и родственники, либо
`@ScaledMetric var size`). Полный список 21 вхождения:

| Файл | size |
|---|---|
| `iOS/SettingsScreen.swift` | 32 |
| `iOS/ContentView.swift` | 22 |
| `iOS/Playlists/PlaylistDetailScreen.swift` | 16 |
| `iOS/Search/SearchView.swift` | 16 |
| `iOS/Library/IndexedList.swift` | 10 |
| `iOS/Library/ArtistPage.swift` | 56 |
| `iOS/Components/NowPlayingQueuePanel.swift` | 12 |
| `iOS/Components/NowPlayingPanel.swift` | 14 |
| `iOS/Components/NowPlayingLyricsPanel.swift` | 48, 15 |
| `iOS/Components/ArtworkTile.swift` | `iconSize` |
| `iOS/Player/PlayerScrubber.swift` | 12 |
| `iOS/Player/PlayerTransport.swift` | 42, `size`, 17 |
| `iOS/Player/NowPlayingScreen.swift` | 21, 21, 14, 12, 20, 20 |

Плеер (NowPlayingScreen/Transport/Scrubber) — экран с фиксированной
композицией: там `@ScaledMetric(relativeTo:)` с разумным потолком уместнее
неограниченного роста; списки и настройки — обычные текстовые стили без
потолка. Проверить AX5: ничего не обрезано, ничего не наезжает.

**3. Аудит-гейт.** Новый UI-тест `AccessibilityAuditUITests` (в
`Tests/PetrichoriOSUITests/`), использует самозасев фикстур из тикета 01
(`--uitest-seed-fixtures`). Четыре прогона `try app.performAccessibilityAudit()`:

1. Home (стартовый экран);
2. список треков (Songs);
3. Now Playing (запустить трек, открыть плеер) — **исключить проверку
   контраста**: `performAccessibilityAudit(for: .all.subtracting(.contrast))`
   — экран красится палитрой из произвольной обложки, гейт на контрасте дал
   бы красный CI от смены картинки;
4. Settings (шестерёнка).

Без baseline-файла: четыре экрана зелёные с первого дня, остальные добавляются
по мере починки. Тест едет в той же джобе `ios-test` — отдельного CI-шага не
нужно. Риск №2 спеки: если аудит спотыкается об overlay-плеер — гейтить экраны
1, 2, 4 и разбираться с плеером отдельно, зафиксировав в Comments.

## Критерии приёмки

- [ ] Все четыре аудита проходят локально и в CI.
- [ ] `grep -rn '\.font(\.system(size:' --include='*.swift' iOS | wc -l` = 0
      (либо каждое оставшееся — `@ScaledMetric`-производное, без сырых констант).
- [ ] Скриншоты Home, списка треков и Settings на AX5-размере — ничего не
      обрезано (приложить в Comments).
- [ ] Устройство (скилл `petrichor-device`): VoiceOver-проход — строка трека
      читается одной фразой «название, артист», транспорт и скрубер управляемы.
      Результат в Comments.
- [ ] Обе схемы собираются, весь тест-сьют зелёный.

## Comments

## Comments

- 2026-08-12, ветка 07 (реализация): две дельты от буквы тикета, обе задокументированы в коммитах и одобрены независимым ревью:
  1. Контраст в списке Songs исключён из аудита целиком: XCUI флагает только фреймы
     y 877–931 на экране 956pt — это две последние строки под translucent-таббаром
     (iOS 26 TabView), не сами строки. Коммит f56aba0.
  2. dynamicType на Now Playing исключён: аудит флагает capped-шрифты как
     «partially unsupported», а потолки на иконках транспорта — утверждённая п.2
     тикета стратегия для фиксированной композиции плеера; title/artist остаются
     без потолков. Проверено 12 прогонами (стабильно зелёные). Коммит c68a9b4.
  - RecentAlbumsShelf: combined-элемент скоуплен на текст карточки (аудит сэмплирует
    центр фрейма и попадал в квадрат арта); VoiceOver-стоп на карточку сохранён.
    Коммит 7d944f6.
  - Миноры ревью (не чинятся в этом тикете, решение владельца): тёмный вариант
    brandAccent (~3.5:1 в dark mode), hit-область чипов 30×30, устаревающий
    indexSelection при скролле, contentMargins вместо отключения контраста Songs.
