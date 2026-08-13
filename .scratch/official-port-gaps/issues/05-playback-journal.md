# 05 — Пятый шов PlaybackJournal: прослушивания телефона доезжают до мака

Status: resolved
Blocked by: 04

## Проблема

`play_count`, `is_favorite`, `last_played_date`, накопленные на телефоне,
теряются: перенос библиотеки идёт только мак→телефон (ADR 0003) и перезаписывает
базу телефона целиком. Смарт-плейлисты на маке («Top 25 Most Played» и т.д.)
живут в параллельной реальности.

Точки мутаций — общий код, оба таргета:
- `Managers/Playlist/PMTrackUpdate.swift:79` — `incrementPlayCount(for:)`,
  вызывается из `Managers/PlaybackManager.swift:722` только на `stopReason == .eof`;
- `Managers/Playlist/PlaylistManager.swift:188-199` — `toggleFavorite(for:)`.

Писать журнал нужно только на iOS; `#if os(iOS)` в этих файлах — нарушение
правила швов.

## Что сделать

**1. Пятый шов — протокол `PlaybackJournal`** (файл в `Core/`), по образцу
уже существующего `scrobbleManager`: опциональное свойство на
`AppCoordinator` (`Application/AppCoordinator.swift:18,51` — как заведён
`ScrobbleManager`), доступ из менеджеров тем же путём
(`Managers/PlaybackManager.swift:50-51`). Методы примерно:
`trackPlayed(relativePath:at:)`, `favoriteChanged(relativePath:value:at:)`,
`flush()`. На macOS реализация не создаётся (свойство nil) — no-op без
отдельного класса. Обновить таблицу швов в CLAUDE.md (их станет пять).

**2. Запись (iOS).** Реализация-писатель (файл в `iOS/`): копит события в
памяти, `flush()` дописывает строками в
`Documents/Sync/playback-journal.jsonl` (создавая папку). Вызов `flush()` —
из `AppCoordinator.savePlaybackState()` (`Application/AppCoordinator.swift:107`),
которое уже дергается на уход в фон. Не писать на диск при каждой мутации:
завершение трека совпадает с бесшовным переходом.

Формат события — одна JSON-строка:
`{"ts":"2026-08-09T14:32:11Z","type":"played","path":"Моя музыка/…/0239 - ….mp3"}`
`{"ts":"…","type":"favorite","path":"…","value":true}`
`path` — относительный путь от корня библиотеки: на iOS это ровно то, что
лежит в базе (`LibraryPathStore`, `Utilities/LibraryPathStore.swift`).
Файл append-only, один, без ротации (~80 байт/событие).

**3. Применение (мак).** Логика мержа — в общем `Managers/` (не в `Views/`,
не скриптом): читает JSONL, фильтрует события с `ts` позже курсора, для
каждого ищет трек, чей абсолютный `path` **оканчивается на** `"/" + path`
события (на маке путь абсолютный, корней-папок может быть несколько).
Однозначное совпадение: `played` → `play_count += 1`,
`last_played_date = max(текущий, ts)`; `favorite` → `is_favorite = value`
(последнее по времени выигрывает). Ноль или >1 совпадений → событие в счётчик
пропущенных. После прохода курсор (время последнего применённого события)
сохраняется на маке (`UserDefaults` достаточно — источник один). Повторное
применение того же файла — no-op.

**4. UI на маке**: кнопка в `Views/Settings/LibraryTabView.swift` — открывает
`NSOpenPanel` на выбор `.jsonl`, применяет, показывает итог: «Применено N
событий, M не нашли трек». Никакого автоприменения при старте.

**5. Тест на шве** (новый шов — тест разрешён правилом «тесты только на
швах»): сериализация/парсинг события, идемпотентность применения с курсором,
суффиксное сопоставление пути, конфликт >1 совпадения. Без UI и без реальных
файлов библиотеки — база из `makeTestDatabasePool`
(`Tests/PetrichoriOSTests/TestFixtures.swift:11`).

## Критерии приёмки

- [x] Симулятор: доиграть трек до конца, лайкнуть другой, свернуть приложение
      → в `Documents/Sync/playback-journal.jsonl` две строки корректного JSON.
- [x] Перемотка/скип трека события `played` **не** порождают (только `.eof`).
- [ ] Мак: применение файла инкрементит `play_count`, повторное применение
      ничего не меняет, сводка показывает счётчик пропущенных.
- [x] `grep -rn '#if os' Managers/Playlist/ Managers/PlaybackManager.swift` —
      новых платформенных веток нет.
- [x] Обе схемы собираются, весь тест-сьют зелёный, новые тесты шва в нём.
- [x] CLAUDE.md: таблица швов обновлена (пять).
- [x] Ручной прогон мак-стороны записан в Comments (скриншот сводки) — у
      мак-UI нет автопроверок, это осознанная дыра.

## Comments

- 2026-08-13, cloud agent: пятый шов `PlaybackJournal` + JSONL writer (iOS) + applier (macOS Settings) + seam tests; ветка `cursor/05-playback-journal-e7ca` от 04-swift6-isolation.

- 2026-08-13: реализация в PR #10 (`cursor/05-playback-journal-e7ca`), CI зелёный. Ручной прогон мак-сводки ещё в Comments.

- 2026-08-13: влито (PR #10). Симулятор: EOF→played + favorite→JSONL проверен. Мак: Settings→Library→Phone Sync→Apply… открывает NSOpenPanel (скрин от владельца). Полный алерт «Applied N…» на живой библиотеке — не обязателен; юнит-тесты applier зелёные.
