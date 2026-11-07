import Foundation

/// Remembers what the keychain answered for each key, so reading a secret
/// again costs a dictionary lookup instead of a `SecItemCopyMatching`.
///
/// On macOS that call goes to the file-based login keychain and can block the
/// main thread for hundreds of milliseconds, and far longer when the system
/// re-checks the item's access list (a re-signed build). Last.fm asks for its
/// session key on every track start, from the main actor.
///
/// An absent value is remembered too: a user who never connected Last.fm
/// would otherwise pay for a keychain miss on every track. Every write goes
/// through `set`, so the cache never disagrees with the keychain this process
/// wrote.
final class SecretCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String?] = [:]

    /// The cached value for `key`, or the one `load` reads, remembered.
    func value(for key: String, load: (String) -> String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = values[key] { return cached }
        let loaded = load(key)
        values[key] = .some(loaded)
        return loaded
    }

    /// Records a write (`nil` for a delete), so the next read skips the keychain.
    func set(_ value: String?, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = .some(value)
    }
}
