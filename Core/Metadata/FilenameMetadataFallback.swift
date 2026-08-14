//
// FilenameMetadataFallback
//
// Разбор имени файла как источника метаданных, когда теги их не содержат.
// Живёт в общем слое, а не в платформенном ридере, чтобы оба таргета
// применяли одно и то же правило.
//
// Библиотека пользователя смешивает два стиля имён: `#### - Исполнитель -
// Название` (числовой префикс задаёт порядок в плейлистах и остаётся частью
// заголовка) и обычный `Исполнитель - Название` без префикса — именно этот
// второй случай встречается чаще всего там, где тег исполнителя реально
// отсутствует.

import Foundation

enum FilenameMetadataFallback {
    private static let separator = " - "

    static func parse(_ url: URL) -> (artist: String?, title: String) {
        let base = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespaces)
        let parts = base.components(separatedBy: separator)

        guard parts.count >= 2 else {
            return (nil, base)
        }

        // `#### - Исполнитель - Название`: префикс остаётся частью заголовка.
        if parts.count >= 3, !parts[0].isEmpty, parts[0].allSatisfy(\.isNumber) {
            let artist = parts[1].trimmingCharacters(in: .whitespaces)
            return (artist, base)
        }

        // `Исполнитель - Название`.
        guard !parts[0].isEmpty, !parts[0].allSatisfy(\.isNumber) else {
            return (nil, base)
        }

        let artist = parts[0].trimmingCharacters(in: .whitespaces)
        let title = parts.dropFirst().joined(separator: separator)
            .trimmingCharacters(in: .whitespaces)
        return (artist, title)
    }
}
