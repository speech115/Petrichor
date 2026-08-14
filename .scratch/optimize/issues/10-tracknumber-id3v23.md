# 10 — `trackNumberInfo`: ID3v2.3 TRCK читается как бинарь

**Status:** ready-for-agent
**Blocked by:** —

`iOS/AVAssetMetadataReader.swift:265-280`:
```swift
if let data = try? await item.load(.dataValue), data.count >= 2 {
    let number = Int(data[0])
    let total = data.count >= 3 ? Int(data[2]) : nil
```
ID3v2.3 `TRCK` — текстовый фрейм: `dataValue` начинается с байта кодировки
(0x00 = latin-1), а значения вида «3/12» — цифры+slash. `Int(data[0])` читает
байт кодировки (→ 0), `Int(data[2])` читает `/` или цифру → мусорный
`totalTracks`. Фикстура `UITestFixtures.swift:84` пишет TRCK как текст
`"\(n)/\(m)"`, так что путь достижим всякий раз, когда `.numberValue` не парсит
slash-форму.

## Направление

Сначала `.stringValue`/`.numberValue`, потом `dataValue` со срезом байта
кодировки и decode как latin-1.
