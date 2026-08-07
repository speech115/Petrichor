# 01 — Шов миниатюр (artwork_thumbnail)

**What to build:** Обложки в базе лежат одним BLOB display-размера
(`artwork_data` на `albums` и `artists`) — тянуть их в списках дорого. Вводится
отдельная миниатюра — общая зависимость всего рескина:

- Новая колонка `artwork_thumbnail` на `albums` и `artists`: ~140 pt (×3 =
  ~420 px), HEIC.
- Генерируется на скане; существующие обложки backfill-ятся **фоновой
  миграцией** по образцу v8 (`DMBackgroundMigration`, конвертация артворка в
  HEIC).
- Реализуется через существующий шов `PlatformImage`, без новых `#if os(...)`.
- Автотест на шве: сборка миниатюры из исходной обложки даёт корректный
  уменьшенный HEIC.
- Обе платформы собираются (схема базы и модели — общие слои).

Спека: `.scratch/apple-music-design/spec.md`, раздел «Шов миниатюр».

**Blocked by:** None — can start immediately.

**Status:** open

- [ ] Миграция v9: колонка `artwork_thumbnail` на `albums` и `artists`
- [ ] Генерация миниатюры при записи обложки на скане (переиспользовать
      `ImageUtils` — HEIC-энкод + ресайз уже есть)
- [ ] Фоновая backfill-миграция по образцу v8 (`v8_background_convert_artwork_to_heic`,
      `DMBackgroundMigration`)
- [ ] Модели `Album`/`Artist`: чтение/запись миниатюры
- [ ] Автотест: уменьшенный HEIC из исходной обложки
- [ ] Обе платформы собираются, тесты зелёные
