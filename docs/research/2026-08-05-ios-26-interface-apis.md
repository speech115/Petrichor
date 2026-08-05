# Интерфейсные API iOS 26, применимые к Petrichor

Дата: 2026-08-05
Статус: проверено

Ресерч под задачу «сделать интерфейс как в Apple Music». Проект собирается под
`IPHONEOS_DEPLOYMENT_TARGET = 26.1` — перегрузка `tabViewBottomAccessory(isEnabled:)`
помечена `@available(iOS 26.1)` в SDK 26.5, поэтому 26.0 не хватает. Начиная с
26.1 вся механика доступна без условной компиляции.

## Как проверялось

Не по блогам. Каждый API найден в `.swiftinterface` установленного SDK:

```
/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/
  iPhoneOS26.5.sdk/System/Library/Frameworks/SwiftUI.framework/Modules/
  SwiftUI.swiftmodule/arm64e-apple-ios.swiftinterface
```

Номера строк ниже — из этого файла. Они сдвинутся при смене Xcode; проверять
надо наличие символа, а не строку.

## Что подтверждено в SDK

| API | Строка | Что даёт |
|---|---|---|
| `tabViewBottomAccessory(content:)` | 13000 | мини-плеер над таб-баром, Liquid Glass и капсула штатно |
| `tabViewBottomAccessory(isEnabled:content:)` | 13007 | **тот же аксессуар с управляемой видимостью** |
| `TabViewBottomAccessoryPlacement` (`.inline` / `.expanded`) | 5329 | сообщает, свернулся ли таб-бар, чтобы перерисовать содержимое |
| `EnvironmentValues.tabViewBottomAccessoryPlacement` | 5308 | чтение этого состояния из вьюхи |
| `tabBarMinimizeBehavior(_:)` | 8540 | `.onScrollDown` — таб-бар сжимается при скролле, аксессуар втягивается в него |
| `TabRole.search` | 12984 | отдельная позиция поиска в таб-баре |
| `Tab.init(role:content:label:)` | 13703–13705 | новый синтаксис вкладок, без которого роли недоступны |
| `matchedTransitionSource(id:in:)` | 14116 | источник зум-перехода; в паре с `.navigationTransition(.zoom)` даёт разворот обложки |
| `searchToolbarBehavior(_:)` | 18882 | поведение поисковой строки в тулбаре |
| `backgroundExtensionEffect()` | 11694 | заливка обложкой под системную хрому |
| `scrollEdgeEffectStyle(_:for:)` | 11770 | размытие у краёв скролла |

`matchedTransitionSource` работает не только для `NavigationStack`, но и для
`sheet` и `fullScreenCover` — доступен с iOS 18.

## Важная деталь про `isEnabled`

В форумах Apple жалуются, что аксессуар нельзя условно показывать: обёртка в
`if` роняет приложение при использовании с `TabView(selection:)`, а в 26.1
видимостью нельзя было управлять вовсе. В SDK 26.5 есть перегрузка
`tabViewBottomAccessory(isEnabled:content:)` — это штатный ответ на проблему.
Аксессуар объявляется всегда, а показывается по флагу.

Практический вывод: не оборачивать в `if playbackManager.currentTrack != nil`,
а передавать это условие в `isEnabled`.

## Что из этого меняет текущий код

`iOS/ContentView.swift` написан до iOS 26 и повторяет руками то, что теперь
системное:

- **Строка 477, `miniPlayerBar`** — `safeAreaInset` + `.ultraThinMaterial` +
  `RoundedRectangle(cornerRadius: 16)` + тень. Это ручная имитация аксессуара.
- **Строка 549, `nowPlayingSheet`** — `.sheet` с `presentationDetents([.medium, .large])`.
  Нарушает принцип anchored origins: путь открытия не совпадает с путём закрытия,
  и разворачивается плеер не из обложки. Нужен `fullScreenCover` с зум-переходом
  от `matchedTransitionSource` на обложке мини-плеера.
- **Строка 57, `TabView(selection:)` с `.tag()`** — старый синтаксис, из-за него
  недоступны `Tab(role: .search)` и вся механика ролей.

## Открытый риск

`tabViewBottomAccessory` — новый API, и жалобы на его поведение в 26.1 в
форумах есть. Телефон работает на iOS 27.0 beta, где поведение может отличаться
от документированного. **Проверять на устройстве до того, как на него ляжет
остальной интерфейс.** Если окажется сырым — откат на текущий `safeAreaInset`,
но Now Playing переделывается в любом случае, он от аксессуара не зависит.

Проверено на устройстве 2026-08-05 (тикет 01): аксессуар живой на iOS 27.0
beta — капсула показывается по `isEnabled`, таб-бар сжимается скроллом,
аксессуар переключает `.inline`/`.expanded`. Откат не потребовался.

## Опен-сорс: что смотреть

Лицензии важны. Petrichor под MIT; копирование кода из GPL-проектов заразит весь
репозиторий. Читать и разбираться можно, копировать нельзя.

| Проект | Лицензия | Ценность |
|---|---|---|
| [BLeeEZ/amperfy](https://github.com/BLeeEZ/amperfy) | **GPL-3.0** | самый зрелый iOS-плеер библиотеки: очередь, CarPlay, Siri |
| [clquwu/Cosmos-Music-Player](https://github.com/clquwu/Cosmos-Music-Player) | **GPL-3.0** | ровно наш кейс — локальные файлы на iPhone |
| [f728743/AppleMusicStylePlayer](https://github.com/f728743/AppleMusicStylePlayer) | MIT | разбор перехода мини-плеер → Now Playing |
| [ryanashcraft/FabBar](https://github.com/ryanashcraft/FabBar) | MIT | воспроизведение Liquid Glass таб-бара |
| [rasmuslos/AmpFin](https://github.com/rasmuslos/AmpFin), [ShelfPlayer](https://github.com/rasmuslos/ShelfPlayer) | архивы | эталон структуры нативного плеера на SwiftUI |

Готового iOS 26 Liquid Glass музыкального плеера в опен-сорсе нет — ниша пустая.

## Источники

- [Donny Wals — Exploring tab bars on iOS 26 with Liquid Glass](https://www.donnywals.com/exploring-tab-bars-on-ios-26-with-liquid-glass/)
- [Hacking with Swift — How to add a TabView accessory](https://www.hackingwithswift.com/quick-start/swiftui/how-to-add-a-tabview-accessory)
- [Hacking with Swift — How to create zoom animations between views](https://www.hackingwithswift.com/quick-start/swiftui/how-to-create-zoom-animations-between-views)
- [Apple Developer Forums — crash when conditionally rendering tabViewBottomAccessory](https://developer.apple.com/forums/thread/790913)
- [Apple Developer Forums — tabViewBottomAccessory cannot control visibility in 26.1](https://developer.apple.com/forums/thread/803404)
