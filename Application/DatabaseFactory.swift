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
        let dbPath = try databaseURL(createDirectory: true).path

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
            let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL(createDirectory: false).path)
            return attributes[.size] as? Int64
        } catch {
            Logger.error("Failed to get database size: \(error)")
            return nil
        }
    }

    /// Файл прод-базы: `Application Support/<bundle-id>/petrichor[-debug].db`.
    /// Папка создаётся только по запросу — запрос размера файла не должен
    /// материализовывать каталог.
    private static func databaseURL(createDirectory: Bool) throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createDirectory
        )
        let bundleID = Bundle.main.bundleIdentifier ?? About.bundleIdentifier
        let appDirectory = appSupport.appendingPathComponent(bundleID, isDirectory: true)

        if createDirectory {
            try FileManager.default.createDirectory(at: appDirectory,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
        }

        let dbFilename = bundleID.hasSuffix(".debug") ? "petrichor-debug.db" : "petrichor.db"
        return appDirectory.appendingPathComponent(dbFilename)
    }
}
