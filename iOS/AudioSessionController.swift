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
    private let onMediaServicesReset: () -> Void
    private let wantsPlayback: () -> Bool
    private var pendingMediaServicesReset: DispatchWorkItem?

    /// True when the app meant to be playing when the interruption began. An
    /// interruption that ends with `.shouldResume` resumes only then: it never
    /// starts audio that was paused when the call/alarm arrived.
    private var wasPlayingBeforeInterruption = false

    init(
        onPause: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onMediaServicesReset: @escaping () -> Void,
        wantsPlayback: @escaping () -> Bool
    ) {
        self.onPause = onPause
        self.onResume = onResume
        self.onMediaServicesReset = onMediaServicesReset
        self.wantsPlayback = wantsPlayback
    }

    private var isObserving = false

    /// Activates the session before playback starts. Returns false when the
    /// system refuses, as it does during a phone call: AVPlayer would then sit
    /// in "waiting to play" over silence while the app showed it playing.
    func activate() -> Bool {
        if !isObserving {
            isObserving = true
            observe()
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            } catch {
                Logger.error("Failed to set the audio session category: \(error)")
            }
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            return true
        } catch {
            Logger.error("The system refused to activate the audio session: \(error)")
            return false
        }
    }

    private func observe() {
        let session = AVAudioSession.sharedInstance()
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }

    /// Sets the category and activates the session. A media services reset
    /// discards both, so playback rebuilt after one calls this again.
    func configureSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            Logger.error("Failed to activate the audio session: \(error)")
        }
    }

    /// Posted with a nil object on iOS 27, and twice for one "Reset All Media
    /// Services": the work is debounced so the player is rebuilt once.
    @objc nonisolated private func handleMediaServicesReset(_ notification: Notification) {
        Logger.info("Audio media services were reset")
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingMediaServicesReset?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        self?.configureSession()
                        self?.onMediaServicesReset()
                    }
                }
                self.pendingMediaServicesReset = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
        }
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

        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        Logger.info("Audio route changed, reason: \(reason.rawValue), outputs: \(outputs.map(\.portType.rawValue))")
        // Pause only when the sound would now come out of the phone itself.
        // AirPods leaving the call profile also report a lost device while
        // staying the output.
        let onPhoneOutput = outputs.contains { $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver }
        if reason == .oldDeviceUnavailable, onPhoneOutput {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    // Headphones unplugged mid-call: the call's end must not
                    // resume playback through the speaker.
                    self?.wasPlayingBeforeInterruption = false
                    self?.onPause()
                }
            }
        }
    }
}
