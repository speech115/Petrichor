# Паритет библиотеки с маком — с чего начать

Ты берёшь один тикет из `issues/` и доводишь его до конца. Этот файл — всё, что
нужно знать до первой строчки кода.

## Прочитай в этом порядке

1. **`/CLAUDE.md`** — правила репозитория. Четыре шва, `Views/` только macOS,
   относительные пути, где живут тесты. Нарушение этих правил — дефект, даже
   если код работает.
2. **`docs/superpowers/specs/2026-08-05-petrichor-ios-design.md`**, разделы
   «Запуск и реконсиляция», «Плейлисты из M3U», «Списки», «Порядок сборки» —
   канон дизайна. Он утверждён. Если код с ним расходится, чинится код, а не
   спека.
3. **`docs/adr/0001-library-reconciliation.md`** и
   **`docs/adr/0002-imported-playlist-outlives-m3u.md`** — решения, на которых
   держится вся эта фича.
4. **`CONTEXT.md`** — глоссарий: канон названий, реконсиляция, Home, Discover.
   Термины из тикетов — отсюда.
5. **`spec.md`** рядом с этим файлом — решения, принятые до тикетов.
6. Свой тикет.

## Как собрать и проверить

```bash
xcodebuild -scheme PetrichoriOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build
xcodebuild test -scheme PetrichoriOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```

Мак тоже должен собираться — общие слои входят в оба таргета:

```bash
xcodebuild -scheme Petrichor -destination 'platform=macOS' build
```

На реальный телефон — `.claude/skills/petrichor-device/scripts/deploy.sh`.
Обычный device destination на этой машине **не работает** — Xcode 26.6 против
iOS 27 beta на устройстве. Не чини его, читай `.claude/skills/petrichor-device/SKILL.md`.

## Порядок

Тикеты 01 и 03 независимы и параллельны. 02 ждёт 01, 04 ждёт все.
