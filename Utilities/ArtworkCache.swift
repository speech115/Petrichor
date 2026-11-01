import Foundation
import os

/// A render whose continuation always resumes. Cancellation goes through
/// `isSkipped`, not `Operation.cancel()`: `start()` never calls `main()` for an
/// operation cancelled before it starts, so its continuation would never resume.
final class ArtworkLoadOperation: Operation, @unchecked Sendable {
    private let continuation: CheckedContinuation<PlatformImage?, Never>
    private let isSkipped: OSAllocatedUnfairLock<Bool>
    private let work: () -> PlatformImage?

    init(
        continuation: CheckedContinuation<PlatformImage?, Never>,
        isSkipped: OSAllocatedUnfairLock<Bool>,
        work: @escaping () -> PlatformImage?
    ) {
        self.continuation = continuation
        self.isSkipped = isSkipped
        self.work = work
        super.init()
    }

    override func main() {
        continuation.resume(returning: isSkipped.withLock { $0 } ? nil : work())
    }
}

extension OperationQueue {
    /// Enqueues a render and resumes its continuation when complete.
    /// Cancelling the awaiting task makes a render that has not started yet
    /// resume with `nil` without rendering.
    func renderArtwork(_ work: @escaping () -> PlatformImage?) async -> PlatformImage? {
        let isSkipped = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.addOperation(ArtworkLoadOperation(continuation: continuation, isSkipped: isSkipped, work: work))
            }
        } onCancel: {
            isSkipped.withLock { $0 = true }
        }
    }
}
