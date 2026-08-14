# 03 — `ColorMode.apply()` — платформенное тело за шов

**Status:** ready-for-agent
**Blocked by:** —

`Utilities/AppAppearance.swift:46-68`: тело `ColorMode.apply()` продублировано
под обе платформы (`NSApp.appearance` vs перебор `UIApplication.shared.connectedScenes`).
Применение цветовой схемы к системному chrome — платформенное различие, которое
сходится в одном месте, но это место не один из пяти швов.

## Направление

Вынести платформенное тело за шов (новый `AppearanceApplier` или расширение
`PlatformShims`); в `ColorMode` остаётся только вызов. Шестой шов — допустимо,
различие не влезает в существующие.
