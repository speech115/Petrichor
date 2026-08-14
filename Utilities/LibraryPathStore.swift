import Foundation

/// Шов путей: переводит между тем, что лежит в базе, и рабочим `URL`.
///
/// На macOS библиотека может лежать где угодно, поэтому путь хранится
/// абсолютным. На iOS музыка всегда внутри контейнера приложения, а UUID
/// контейнера не стабилен между установками — там хранится путь относительно
/// `Documents`, а абсолютный собирается в рантайме.
///
/// Bookmark create/resolve options live here too: macOS needs security scope
/// to reopen folders outside the sandbox; iOS music stays in the container.
enum LibraryPathStore {
    /// Корень, относительно которого хранятся пути.
    static var libraryRoot: URL {
        #if os(iOS)
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #else
        URL(fileURLWithPath: "/")
        #endif
    }

    /// Options for `URL.bookmarkData(options:…)` when persisting a library folder.
    static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    /// Options for `URL(resolvingBookmarkData:options:…)`.
    static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    /// Bookmark data to persist for a folder row. iOS music stays inside the
    /// container, where security-scoped bookmarks are not needed, so it stores
    /// `nil`; macOS persists the data to reopen folders outside its sandbox.
    static func storedBookmarkData(for bookmarkData: Data?) -> Data? {
        #if os(iOS)
        return nil
        #else
        return bookmarkData
        #endif
    }

    /// Путь для записи в базу.
    static func storedPath(for url: URL) -> String {
        // /var is a symlink to /private/var on iOS; enumeration can hand back
        // either spelling, so both sides must resolve symlinks or the same
        // file never compares equal.
        let root = libraryRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path

        #if os(iOS)
        // The library root itself (e.g. registering Documents as a Folder) has no
        // trailing slash to strip, so it needs its own case: it stores as "".
        if path == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
        #else
        return path
        #endif
    }

    /// Рабочий `URL` из того, что лежит в базе.
    static func url(fromStored path: String) -> URL {
        guard !path.hasPrefix("/") else { return URL(fileURLWithPath: path) }
        return libraryRoot.appendingPathComponent(path)
    }
}
