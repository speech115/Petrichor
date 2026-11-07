//
// CoalescingRunner
//
// Runs one operation at a time without dropping requests. A request that
// arrives while a run is in flight cannot be served by that run: it may
// already have read the state the request is about (a file copied in after
// the scan listed the folder). So it waits for exactly one follow-up run,
// which every request arriving meanwhile shares. A caller returns only after
// a run that started after its request has finished.
//
// See docs/state-machines.md, SM-5 / SM-6 (I-5.2, I-6.3).
//

import Foundation

@MainActor
final class CoalescingRunner {
    private var running: Task<Void, Error>?
    private var followUp: Task<Void, Error>?

    /// Whether a run is in flight.
    var isRunning: Bool { running != nil }

    /// Runs `operation`, or joins the follow-up run when one is in flight.
    /// Throws what the run this caller waited for threw.
    func run(_ operation: @escaping @MainActor @Sendable () async throws -> Void) async throws {
        if let followUp {
            try await followUp.value
            return
        }
        guard let previous = running else {
            let task = Task { @MainActor in try await operation() }
            running = task
            defer { if running == task { running = nil } }
            try await task.value
            return
        }

        // Starts only once the run in flight has ended, whatever it threw.
        let task = Task { @MainActor [weak self] in
            _ = await previous.result
            if let self {
                self.running = self.followUp
                self.followUp = nil
            }
            try await operation()
        }
        followUp = task
        defer { if running == task { running = nil } }
        try await task.value
    }
}

/// The actor-side counterpart for fire-and-forget work (the Spotlight sync):
/// a trigger that arrives mid-run asks the run to go again instead of being
/// dropped. A pure value, so its transitions are property-tested directly.
struct RerunGate: Equatable, Sendable {
    private(set) var isRunning = false
    private(set) var rerunRequested = false

    /// Called on every trigger. True: the caller starts the run now. False:
    /// a run is in flight and will go again.
    mutating func request() -> Bool {
        guard !isRunning else {
            rerunRequested = true
            return false
        }
        isRunning = true
        return true
    }

    /// Called when a pass ends. True: run another pass (still running).
    /// False: the gate is idle.
    mutating func finishPass() -> Bool {
        if rerunRequested {
            rerunRequested = false
            return true
        }
        isRunning = false
        return false
    }
}
