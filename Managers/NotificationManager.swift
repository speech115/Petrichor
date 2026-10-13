//
// NotificationManager
//
// The "activity in progress" flag scan/optimize code drives, plus a message
// sink for scan and playback errors. Messages go to the log only: the macOS
// toolbar notifications popover was removed.
//

import Combine
import Foundation

// MARK: - Notification Types

enum NotificationType {
    case info
    case warning
    case error
}

// MARK: - Notification Manager

@MainActor
class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published var isActivityInProgress = false
    @Published var activityMessage = ""
    @Published var activityProgress: ActivityProgress?

    private var lastProgressUpdateTime: Date = .distantPast
    private let progressUpdateInterval: TimeInterval = 0.5

    struct ActivityProgress {
        let current: Int
        let total: Int
        let detail: String?

        var fraction: Double {
            guard total > 0 else { return 0 }
            return Double(current) / Double(total)
        }
    }

    private init() {
        // Drop messages persisted by the removed notifications popover
        UserDefaults.standard.removeObject(forKey: "NotificationTrayMessages")
    }

    // MARK: - Activity Management

    func startActivity(_ message: String) {
        isActivityInProgress = true
        activityMessage = message
        activityProgress = nil
        lastProgressUpdateTime = .distantPast
    }

    func stopActivity() {
        isActivityInProgress = false
        activityMessage = ""
        activityProgress = nil
    }

    func updateActivityProgress(current: Int, total: Int, detail: String? = nil) {
        let now = Date()
        guard now.timeIntervalSince(lastProgressUpdateTime) >= progressUpdateInterval else { return }
        lastProgressUpdateTime = now

        activityProgress = ActivityProgress(
            current: current,
            total: total,
            detail: detail
        )
    }

    // MARK: - Message Management

    func addMessage(_ type: NotificationType, _ title: String) {
        switch type {
        case .info: Logger.info(title)
        case .warning: Logger.warning(title)
        case .error: Logger.error(title)
        }
    }
}
