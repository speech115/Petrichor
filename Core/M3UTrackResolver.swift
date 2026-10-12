//
// M3UTrackResolver
//
// Шов «матчинг M3U»: как запись плейлиста (строка пути из файла) находит
// трек в библиотеке. Раньше эта логика жила в `PMImportExport.matchTracksToLibrary`
// и опиралась на два запроса, встроивших политику неоднозначности в себя
// (`findTracksByFilenames`/`findTracksByNormalizedFilenames` в DMQueries);
// теперь весь трёхстадийный фолбэк и политика «откажись от неоднозначного»
// собраны здесь, в одном месте, а база предоставляет только узкие примитивы
// через `Query`.
//
// Три стадии, в порядке приоритета:
// 1. путь — каждая вариация пути записи (см. `pathVariations`) ищется
//    напрямую в базе;
// 2. точное имя файла — батч-запрос по именам, коллизии (два трека на одно
//    имя) вычёркиваются;
// 3. нормализованное имя — для переименованных при переносе файлов (числовые
//    префиксы сняты, `,` → `;`): имена записей маппятся на кандидатов через
//    `M3UFilenameNormalizer`, ключи с коллизиями блокируются.
//

import Foundation

enum M3UTrackResolver {
    /// Узкий интерфейс к библиотеке: то, что трём стадиям нужно от базы, и
    /// ничего больше. Реализует `DatabaseManager` (см. `m3uQuery()`).
    struct Query {
        /// Трек по пути (со швом `LibraryPathStore` внутри) — стадия 1.
        var findTrackByPath: (String) async -> Track?
        /// Все треки, чьи имена файлов есть в списке — стадии 2 и 3.
        /// Без политики неоднозначности: сырые строки базы.
        var tracksByFilenames: ([String]) async -> [Track]
        /// Все имена файлов в библиотеке — кандидаты стадии 3.
        var storedFilenames: () async -> [String]
    }

    /// Шов «Разбор M3U»: кандидатные пути одной записи, в порядке приоритета
    /// матчинга. Относительная запись (`../Spotify/x.mp3`) разрешается
    /// относительно папки самого M3U; макош-абсолютные пути нормализуются
    /// как фолбэки. Первая вариация — то, с чем `findTrackByPath` сравнивает
    /// сохранённый в базе (Documents-относительный) путь.
    static func pathVariations(for path: String, sourceDirectory: URL? = nil) -> [String] {
        var normalized = path

        for scheme in ["file://", "smb://", "afp://", "nfs://"] where normalized.lowercased().hasPrefix(scheme) {
            normalized = String(normalized.dropFirst(scheme.count))
            break
        }

        // Handle Windows-style UNC paths (leading double-slash, e.g. server/share)
        if normalized.hasPrefix("//") {
            normalized = "/Volumes" + String(normalized.dropFirst(1))
        }

        normalized = normalized.replacingOccurrences(of: "\\", with: "/")

        // URL decode
        normalized = normalized.removingPercentEncoding ?? normalized

        var variations = [normalized]

        if normalized.hasPrefix("/Volumes/") {
            variations.append(String(normalized.dropFirst(8)))
        } else if normalized.hasPrefix("/") && !normalized.hasPrefix("/Users/") {
            variations.append("/Volumes" + normalized)
        } else if !normalized.hasPrefix("/"), let sourceDirectory {
            var relativePath = normalized
            while relativePath.hasPrefix("./") {
                relativePath = String(relativePath.dropFirst(2))
            }
            let resolved = sourceDirectory.appendingPathComponent(relativePath).standardizedFileURL.path
            variations.insert(resolved, at: 0)
        }

        return variations
    }

    /// Матчит записи M3U против библиотеки. Результат — один элемент на
    /// входную запись, в том же порядке: трек или nil (не найдено/отказано
    /// из-за неоднозначности). Вызывающая сторона знает, какая запись чему
    /// соответствует, по индексу — никакой словарной двойной опциональности.
    static func resolveTracks(
        for paths: [String],
        sourceDirectory: URL? = nil,
        using query: Query
    ) async -> [Track?] {
        var resolved: [Track?] = []
        resolved.reserveCapacity(paths.count)
        var unmatched: [(index: Int, path: String)] = []

        // Стадия 1: прямой матч по пути (вариации записи → путь в базе).
        for (index, path) in paths.enumerated() {
            var matched: Track?
            for variation in pathVariations(for: path, sourceDirectory: sourceDirectory) {
                if let track = await query.findTrackByPath(variation) {
                    matched = track
                    break
                }
            }
            resolved.append(matched)
            if matched == nil {
                unmatched.append((index, path))
            }
        }

        // Стадия 2: точное имя файла, батчем.
        if !unmatched.isEmpty {
            let filenames = unmatched.map { ($0.path as NSString).lastPathComponent }
            let byName = await tracksByExactFilenames(filenames, using: query)

            var stillUnmatched: [(index: Int, path: String)] = []
            for entry in unmatched {
                let filename = (entry.path as NSString).lastPathComponent.lowercased()
                if let track = byName[filename] {
                    resolved[entry.index] = track
                } else {
                    stillUnmatched.append(entry)
                }
            }
            unmatched = stillUnmatched
        }

        // Стадия 3: переименованные при переносе файлы (числовые префиксы
        // сняты, `,` → `;`), так что даже точное имя не попадает. Матчим
        // нормализованный ключ; ключи, на которые схлопнулось несколько
        // кандидатов, блокируются и не резолвятся.
        if !unmatched.isEmpty {
            let filenames = unmatched.map { ($0.path as NSString).lastPathComponent }
            let candidates = await query.storedFilenames()
            let keyMap = resolveByNormalizedKeys(filenames, against: candidates)

            if !keyMap.isEmpty {
                let byName = await tracksByExactFilenames(Array(keyMap.values), using: query)
                for entry in unmatched {
                    let filename = (entry.path as NSString).lastPathComponent
                    if let candidate = keyMap[filename],
                       let track = byName[candidate.lowercased()] {
                        resolved[entry.index] = track
                    }
                }
            }
        }

        return resolved
    }

    // MARK: - Policy helpers

    /// Имя файла (lowercased) → единственный трек, по одному батч-запросу.
    /// Имя, под которым в базе несколько треков (коллизия), вычёркивается:
    /// угадывать между ними нельзя. Это политика «откажись от неоднозначного»
    /// в единственном месте — стадии 2 и 3 обе идут через неё.
    private static func tracksByExactFilenames(
        _ filenames: [String],
        using query: Query
    ) async -> [String: Track] {
        let tracks = await query.tracksByFilenames(filenames)
        var result: [String: Track] = [:]
        var ambiguous: Set<String> = []
        for track in tracks {
            let key = track.url.lastPathComponent.lowercased()
            if result[key] == nil {
                result[key] = track
            } else {
                ambiguous.insert(key)
            }
        }
        for key in ambiguous {
            result.removeValue(forKey: key)
        }
        return result
    }

    /// Маппит запрошенное имя на единственного кандидата с тем же
    /// нормализованным ключом, или пропускает его, когда кандидатов нет или
    /// больше одного. Ключ остаётся заблокированным после первой коллизии:
    /// с тремя кандидатами на одном ключе удаление второго сделало бы третий
    /// снова «однозначным». Один проход по всем кандидатам держит стадию
    /// линейной по размеру библиотеки вместо квадратичной.
    private static func resolveByNormalizedKeys(
        _ filenames: [String],
        against candidates: [String]
    ) -> [String: String] {
        var keyToName: [String: String] = [:]
        var blockedKeys: Set<String> = []
        for candidate in candidates {
            let key = M3UFilenameNormalizer.normalize(candidate)
            if blockedKeys.contains(key) {
                continue
            }
            if keyToName[key] == nil {
                keyToName[key] = candidate
            } else {
                keyToName.removeValue(forKey: key)
                blockedKeys.insert(key)
            }
        }

        var resolved: [String: String] = [:]
        for filename in filenames {
            let key = M3UFilenameNormalizer.normalize(filename)
            if !blockedKeys.contains(key), let name = keyToName[key] {
                resolved[filename] = name
            }
        }
        return resolved
    }
}
