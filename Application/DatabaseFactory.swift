//
// DatabaseFactory
//
// Собирает прод-пул базы вне `DatabaseManager`: менеджер принимает готовый
// `DatabasePool` (тесты передают in-memory), а путь к файлу и PRAGMA-конфиг
// живут здесь, у вызывающей стороны. Размер файла тоже спрашивают здесь —
// менеджер пул строит, но файлом больше не владеет.
//

import Foundation
import GRDB

enum DatabaseFactory {
    /// Открывает (или создаёт) файловую базу под Application Support:
    /// папка с именем бандла, `.debug`-суффикс в имени файла для debug-сборок,
    /// PRAGMA-настройки на соединение.
    static func makeApplicationSupportPool() throws -> DatabasePool {
        // Create database in app support directory
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // Use bundle identifier as the folder name
        let bundleID = Bundle.main.bundleIdentifier ?? About.bundleIdentifier
        let appDirectory = appSupport.appendingPathComponent(bundleID, isDirectory: true)

        // Create directory if it doesn't exist
        try FileManager.default.createDirectory(at: appDirectory,
                                                withIntermediateDirectories: true,
                                                attributes: nil)

        let dbFilename = bundleID.hasSuffix(".debug") ? "petrichor-debug.db" : "petrichor.db"
        let dbPath = appDirectory.appendingPathComponent(dbFilename).path

        // Configure database before creating the queue
        var config = Configuration()
        config.prepareDatabase { db in
            // DatabasePool manages WAL itself; NORMAL sync and a busy timeout
            // are the recommended per-connection settings under WAL.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }

        return try DatabasePool(path: dbPath, configuration: config)
    }

    /// Размер файла прод-базы (для отчётов «сколько освободили» после
    /// оптимизации). In-memory пулы в тестах файла не имеют — спрашивать
    /// размер можно только у файловой базы, собранной этим фабричным путём.
    static func databaseFileSize() -> Int64? {
        do {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
            let bundleID = Bundle.main.bundleIdentifier ?? About.bundleIdentifier
            let dbFilename = bundleID.hasSuffix(".debug") ? "petrichor-debug.db" : "petrichor.db"
            let dbPath = appSupport
                .appendingPathComponent(bundleID, isDirectory: true)
                .appendingPathComponent(dbFilename).path
            let attributes = try FileManager.default.attributesOfItem(atPath: dbPath)
            return attributes[.size] as? Int64
        } catch {
            Logger.error("Failed to get database size: \(error)")
            return nil
        }
    }
}
