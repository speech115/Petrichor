import Foundation

/// The keychain read path as it stands: every read goes to the keychain.
/// Introduced with its tests first, so they fail against today's behaviour.
final class SecretCache: @unchecked Sendable {
    func value(for key: String, load: (String) -> String?) -> String? {
        load(key)
    }

    func set(_ value: String?, for key: String) {}
}
