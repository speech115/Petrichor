import AVFoundation
import Foundation
import Testing
@testable import Petrichor

/// `AVQueuePlayerBackend.mapPlaybackError(_:)` is a pure function of the
/// `Error` AVFoundation hands back for a failed queue item, so it is testable
/// without a real `AVPlayerItem` failure - that needs a genuinely
/// missing/corrupt file on disk and belongs to the device checkpoint
/// (Task 12), not a unit test.
@Suite struct PlaybackErrorMappingTests {
    @Test func missingFileReportedByCocoaDomainMapsToFileNotFound() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)

        #expect(isFileNotFound(AVQueuePlayerBackend.mapPlaybackError(error)))
    }

    @Test func missingFileReportedByURLDomainMapsToFileNotFound() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)

        #expect(isFileNotFound(AVQueuePlayerBackend.mapPlaybackError(error)))
    }

    @Test func fileNotFoundNestedAsUnderlyingErrorStillMapsToFileNotFound() {
        let underlying = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        let wrapper = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.unknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )

        #expect(isFileNotFound(AVQueuePlayerBackend.mapPlaybackError(wrapper)))
    }

    @Test func unrecognizedFormatMapsToInvalidFormat() {
        let error = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.fileFormatNotRecognized.rawValue)

        #expect(isInvalidFormat(AVQueuePlayerBackend.mapPlaybackError(error)))
    }

    @Test func decodeFailureMapsToInvalidFormat() {
        let error = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decodeFailed.rawValue)

        #expect(isInvalidFormat(AVQueuePlayerBackend.mapPlaybackError(error)))
    }

    @Test func unrelatedAVFoundationErrorMapsToEngineError() {
        let error = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.deviceNotConnected.rawValue)

        #expect(isEngineError(AVQueuePlayerBackend.mapPlaybackError(error)))
    }

    @Test func nilErrorStillMapsToAnEngineError() {
        #expect(isEngineError(AVQueuePlayerBackend.mapPlaybackError(nil)))
    }
}

private func isFileNotFound(_ error: AudioPlayerError) -> Bool {
    if case .fileNotFound = error { return true }
    return false
}

private func isInvalidFormat(_ error: AudioPlayerError) -> Bool {
    if case .invalidFormat = error { return true }
    return false
}

private func isEngineError(_ error: AudioPlayerError) -> Bool {
    if case .engineError = error { return true }
    return false
}
