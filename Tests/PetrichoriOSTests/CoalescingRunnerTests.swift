import Foundation
import Testing
@testable import Petrichor

// Property and example tests for the single-flight gates behind the scan,
// reconciliation and Spotlight sync (docs/state-machines.md, I-5.1, I-5.2,
// I-6.3).

/// SplitMix64: a fixed seed gives the same event sequences on every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// For any interleaving of triggers and pass ends: one pass at a time, the
/// gate's view matches the driver's, and every trigger is served by a pass
/// that starts at or after it.
@Test(arguments: 0..<200)
func rerunGateServesEveryTriggerWithALaterPass(seed: Int) {
    var random = SeededGenerator(seed: UInt64(seed))
    var gate = RerunGate()
    var passRunning = false
    var triggers: [Int] = []
    var passStarts: [Int] = []

    let length = Int.random(in: 1...40, using: &random)
    for step in 0..<length {
        if !passRunning || Bool.random(using: &random) {
            triggers.append(step)
            if gate.request() {
                #expect(!passRunning, "a second pass started while one ran")
                passRunning = true
                passStarts.append(step)
            }
        } else if gate.finishPass() {
            passStarts.append(step)
        } else {
            passRunning = false
        }
        #expect(gate.isRunning == passRunning)
    }
    while passRunning {
        if gate.finishPass() {
            passStarts.append(length)
        } else {
            passRunning = false
        }
    }

    #expect(gate == RerunGate(), "the gate must end idle")
    for trigger in triggers {
        #expect(passStarts.contains { $0 >= trigger }, "trigger at \(trigger) was dropped, passes: \(passStarts)")
    }
}

/// A manual latch the test opens to let a blocked operation finish.
@MainActor
private final class Latch {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Counters shared between the test and the operations it runs.
@MainActor
private final class RunLog {
    var runs = 0
    var requests = 0
    var requestsBeforeLastRun = 0
}

@MainActor
@Test func requestsDuringARunShareOneFollowUpRunThatStartsAfterThem() async throws {
    let runner = CoalescingRunner()
    let firstRunMayEnd = Latch()
    let log = RunLog()

    let operation: @MainActor @Sendable () async throws -> Void = {
        log.runs += 1
        log.requestsBeforeLastRun = log.requests
        if log.runs == 1 { await firstRunMayEnd.wait() }
    }

    log.requests += 1
    let first = Task { try await runner.run(operation) }
    while log.runs == 0 { await Task.yield() }

    var followers: [Task<Void, Error>] = []
    for _ in 0..<3 {
        log.requests += 1
        followers.append(Task { try await runner.run(operation) })
    }
    for _ in 0..<10 { await Task.yield() }
    #expect(log.runs == 1, "a request ran in parallel with the run in flight")

    firstRunMayEnd.open()
    try await first.value
    for follower in followers { try await follower.value }

    #expect(log.runs == 2, "the three requests must share exactly one follow-up run")
    #expect(log.requestsBeforeLastRun == log.requests, "the follow-up must start after every request it serves")
    #expect(!runner.isRunning)
}

@MainActor
@Test func aFailedRunStillLetsTheFollowUpRun() async throws {
    struct Boom: Error {}
    let runner = CoalescingRunner()
    let firstRunMayEnd = Latch()
    let log = RunLog()

    let first = Task {
        try await runner.run {
            log.runs += 1
            await firstRunMayEnd.wait()
            throw Boom()
        }
    }
    while log.runs == 0 { await Task.yield() }
    let follower = Task { try await runner.run { log.runs += 1 } }
    for _ in 0..<10 { await Task.yield() }

    firstRunMayEnd.open()
    await #expect(throws: Boom.self) { try await first.value }
    try await follower.value
    #expect(log.runs == 2)
    #expect(!runner.isRunning)
}
