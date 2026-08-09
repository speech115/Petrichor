# 05 — Меню трека хостило SwiftUI-вьюхи вместо нативных UIAction

**What to build:** Меню под троеточием в плеере должно раскрываться с готовым
содержимым. Сейчас надписи «сначала серые/тёмные», нормальными становятся к
концу анимации.

**Status:** resolved

## Причина

Плеер строил меню макосным `TrackContextMenuContent` из
`Views/Components/TrackView.swift`. Каждый пункт там —

```swift
Button(action: action) {
    HStack { Image(systemName: icon); Text(title); Spacer() }
}
.buttonStyle(.plain)
```

UIKit превращает пункт SwiftUI-меню в `UIAction`, только если лейбл — `Text` или
`Label`. `HStack` со `Spacer` и `.buttonStyle` заставляют SwiftUI **хостить
вьюху** внутри `UIMenu`. Хостед-вьюха не готова к первому кадру раскрытия и не
подчиняется оформлению меню, отсюда серые заглушки на всю анимацию.

Вторым эффектом: `TrackContextMenuContent(items: contextMenuItems)` вычисляет
массив пунктов **в теле родителя**, то есть на каждой перерисовке
`NowPlayingScreen` — включая каждый кадр свайпа. Внутри — обход
`LibraryFilterType.allCases` с разбором артистов и полный список плейлистов.
Нативное `Menu { … }` строит содержимое лениво.

`iOS/Components/TrackRow.swift` уже делал всё правильно — `Button` + `Label`.
Общая часть вынесена в `iOS/Components/TrackMenuContent.swift`, строка кладёт
поверх свои пункты воспроизведения, плеер использует её как есть. Макосный
`TrackContextMenu` остаётся у макоси нетронутым.

- [x] `iOS/Components/TrackMenuContent.swift` — только `Button` + `Label`
- [x] `TrackRow` использует его, дубли из строки удалены вместе с
      `goToDestinations`, `showTrackInfo` и `TrackFilterDestination`
- [x] `NowPlayingScreen` использует его; `contextMenuItems` удалён
- [x] Комментарий в шапке объясняет, почему лейбл обязан быть голым `Label`
- [x] Покадрово: содержимое меню (иконки, подписи, шевроны подменю) отрисовано
      на первом же кадре раскрытия и масштабируется целиком
