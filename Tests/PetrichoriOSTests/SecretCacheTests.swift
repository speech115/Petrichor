import Foundation
import Testing
@testable import Petrichor

// The Last.fm session key is read on every track start, on the main actor.
// On macOS each read was a SecItemCopyMatching against the login keychain
// that held the main thread for 0.4 s or more after a double-click. These
// tests pin that a secret is read from the keychain at most once per key.

/// A keychain stand-in that counts reads per key.
private final class CountingStore {
    var stored: [String: String]
    private(set) var reads: [String: Int] = [:]

    init(_ stored: [String: String]) { self.stored = stored }

    func read(_ key: String) -> String? {
        reads[key, default: 0] += 1
        return stored[key]
    }
}

/// For any sequence of reads, writes and deletes over a few keys: every read
/// returns what the keychain holds, and each key is read from the keychain at
/// most once.
@Test(arguments: 0..<100)
func secretCacheReadsEachKeyOnceAndStaysTrue(seed: Int) {
    var random = SeededGenerator(seed: UInt64(seed))
    let keys = ["session", "other", "missing"]
    let store = CountingStore(["session": "s0", "other": "o0"])
    let cache = SecretCache()

    for step in 0..<60 {
        let key = keys[Int(random.next() % UInt64(keys.count))]
        switch random.next() % 4 {
        case 0:
            let value = "v\(step)"
            store.stored[key] = value
            cache.set(value, for: key)
        case 1:
            store.stored[key] = nil
            cache.set(nil, for: key)
        default:
            #expect(cache.value(for: key, load: store.read) == store.stored[key])
        }
    }

    for key in keys {
        #expect(store.reads[key, default: 0] <= 1, "\(key) was read from the keychain \(store.reads[key, default: 0]) times")
    }
}

/// The case behind the bug: a user who never connected Last.fm. A miss is
/// remembered, not re-asked on every track.
@Test
func secretCacheRemembersAMiss() {
    let store = CountingStore([:])
    let cache = SecretCache()

    for _ in 0..<5 {
        #expect(cache.value(for: "session", load: store.read) == nil)
    }

    #expect(store.reads["session"] == 1)
}
