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
        try makePool(at: databaseURL(createDirectory: true))
    }

    /// Пул на файле `url` с прод-настройками соединения; тесты открывают так
    /// базу во временной папке.
    static func makePool(at url: URL) throws -> DatabasePool {
        // Configure database before creating the queue
        var config = Configuration()
        config.prepareDatabase { db in
            // DatabasePool manages WAL itself; NORMAL sync and a busy timeout
            // are the recommended per-connection settings under WAL.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }

        return try DatabasePool(path: url.path, configuration: config)
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

    /// Удаляет файл прод-базы вместе с `-wal` и `-shm`: сброс библиотеки, когда
    /// базу не удаётся открыть. Отсутствующий файл сбросу не мешает.
    static func removeDatabaseFiles() throws {
        try removeDatabaseFiles(at: databaseURL(createDirectory: false))
    }

    static func removeDatabaseFiles(at url: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            try FileManager.default.removeItem(at: file)
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
