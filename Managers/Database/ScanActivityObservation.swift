//
// ScanActivityObservation
//
// Main-actor observation of library scan activity. Owns the `isScanning` /
// `scanStatusMessage` state that used to live on `DatabaseManager` (which is
// otherwise a pure `DatabasePool` wrapper and can therefore be `Sendable`),
// plus the throttle that keeps high-frequency progress updates from
// republishing a new `scanStatusMessage` on every processed batch.
//
// Mirrors the narrow-observation pattern of `PlaybackPresentationObservation`
// / `PlaybackProgressState` in `PlaybackManager`; `LibraryManager` mirrors
// the two `@Published` values onto its own published surface for the views.
//

import Combine
import Foundation

@MainActor
final class ScanActivityObservation: ObservableObject {
    @Published var isScanning: Bool = false
    @Published var scanStatusMessage: String = ""

    private var lastStatusUpdateTime: Date = .distantPast
    private let statusUpdateInterval: TimeInterval = 0.5

    /// `nonisolated` so `DatabaseManager` (itself not main-actor-isolated,
    /// since it must be constructible off the main actor in tests) can
    /// create the observation as a stored-property default. Only sets
    /// stored properties to literal defaults — no main-actor state is
    /// touched, which is what makes a `nonisolated init` on an otherwise
    /// `@MainActor` type sound.
    nonisolated init() {}

    /// Throttled status update: high-frequency progress callbacks (one per
    /// processed batch) only republish at most every `statusUpdateInterval`.
    /// Main-actor isolated, so the throttle state is no longer touched from
    /// background scan threads.
    func updateStatus(_ message: String) {
        let now = Date()
        guard now.timeIntervalSince(lastStatusUpdateTime) >= statusUpdateInterval else { return }
        lastStatusUpdateTime = now
        scanStatusMessage = message
    }

    /// Ends a scan: clears the scanning flag and the status message.
    func finishScan() {
        isScanning = false
        scanStatusMessage = ""
    }
}
