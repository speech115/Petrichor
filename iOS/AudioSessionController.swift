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

final class AudioSessionController {
    private let onPause: () -> Void
    private let onResume: () -> Void

    init(onPause: @escaping () -> Void, onResume: @escaping () -> Void) {
        self.onPause = onPause
        self.onResume = onResume
    }

    func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

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

    @objc private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            onPause()
        case .ended:
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                onResume()
            }
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }

        if reason == .oldDeviceUnavailable { onPause() }
    }
}
