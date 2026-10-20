//
// AudioSessionController
//
// Owns the app's `AVAudioSession` configuration and reacts to interruptions
// and route changes so background playback behaves the way the system
// expects it to: a phone call or alarm pauses and resumes playback, and
// unplugging headphones pauses instead of continuing out loud through the
// speaker.
//

import AVFoundation

@MainActor
final class AudioSessionController {
    private let onPause: () -> Void
    private let onResume: () -> Void
    private let wantsPlayback: () -> Bool

    /// True when the app meant to be playing when the interruption began. An
    /// interruption that ends with `.shouldResume` resumes only then: it never
    /// starts audio that was paused when the call/alarm arrived.
    private var wasPlayingBeforeInterruption = false

    init(
        onPause: @escaping () -> Void,
        onResume: @escaping () -> Void,
        wantsPlayback: @escaping () -> Bool
    ) {
        self.onPause = onPause
        self.onResume = onResume
        self.wantsPlayback = wantsPlayback
    }

    func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            Logger.error("Failed to activate the audio session: \(error)")
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Notifications

    // Interruption/route-change notifications are not guaranteed to arrive on
    // the main thread, but `onPause`/`onResume`/`isPlaying` touch MainActor
    // backend state. The main-queue FIFO hop mirrors
    // `AVQueuePlayerBackend.enqueueAVFoundationEvent`.

    @objc nonisolated private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.wasPlayingBeforeInterruption = self.wantsPlayback()
                    Logger.info("Audio interruption began, was playing: \(self.wasPlayingBeforeInterruption)")
                    self.onPause()
                }
            }
        case .ended:
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Logger.info("Audio interruption ended, should resume: \(shouldResume), was playing: \(self.wasPlayingBeforeInterruption)")
                    guard shouldResume, self.wasPlayingBeforeInterruption else { return }
                    self.reactivateSession()
                    self.onResume()
                }
            }
        @unknown default:
            break
        }
    }

    @objc nonisolated private func handleRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }

        Logger.info("Audio route changed, reason: \(reason.rawValue)")
        if reason == .oldDeviceUnavailable {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.onPause()
                }
            }
        }
    }

    /// Re-activates the session after an interruption. The system deactivates
    /// it during a call/alarm; resuming against an inactive session would
    /// play silently.
    private func reactivateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Logger.error("Failed to re-activate the audio session after interruption: \(error)")
        }
    }
}
