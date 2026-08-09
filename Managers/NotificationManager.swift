//
// NotificationManager
//
// In-app notification tray state: transient error/warning/info messages plus
// the long-running "activity in progress" flag scan/optimize code drives.
// Shared by both platforms (`DM*`/`LM*` scan code and `PlaybackManager` post
// through it, iOS's `SettingsScreen` reads its activity state directly), so
// it lives here rather than in `Views/Components/Widgets/NotificationTray.swift`,
// which now holds only the macOS tray UI (`NotificationTray`, `NotificationPopover`,
// `NotificationRow`) that renders it.
//

import SwiftUI

// MARK: - Notification Types

enum NotificationType {
    case info
    case warning
    case error

    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }
}

struct NotificationMessage: Identifiable {
    let id = UUID()
    let type: NotificationType
    let title: String
    let timestamp: Date

    init(type: NotificationType, title: String) {
        self.type = type
        self.title = title
        self.timestamp = Date()
    }
}

// MARK: - Notification Manager

class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published var isActivityInProgress = false
    @Published var activityMessage = ""
    @Published var activityProgress: ActivityProgress?
    @Published var messages: [NotificationMessage] = []

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

    private let messagesKey = "NotificationTrayMessages"

    private init() {
        loadPersistedMessages()
    }

    // MARK: - Activity Management

    func startActivity(_ message: String) {
        guard !Thread.isMainThread else {
            isActivityInProgress = true
            activityMessage = message
            activityProgress = nil
            lastProgressUpdateTime = .distantPast
            return
        }

        DispatchQueue.main.async {
            self.isActivityInProgress = true
            self.activityMessage = message
            self.activityProgress = nil
            self.lastProgressUpdateTime = .distantPast
        }
    }

    func stopActivity() {
        guard !Thread.isMainThread else {
            isActivityInProgress = false
            activityMessage = ""
            activityProgress = nil
            return
        }

        DispatchQueue.main.async {
            self.isActivityInProgress = false
            self.activityMessage = ""
            self.activityProgress = nil
        }
    }

    func updateActivityProgress(current: Int, total: Int, detail: String? = nil) {
        let now = Date()
        guard now.timeIntervalSince(lastProgressUpdateTime) >= progressUpdateInterval else { return }
        lastProgressUpdateTime = now

        DispatchQueue.main.async {
            self.activityProgress = ActivityProgress(
                current: current,
                total: total,
                detail: detail
            )
        }
    }

    // MARK: - Message Management

    func addMessage(_ type: NotificationType, _ title: String) {
        DispatchQueue.main.async {
            let message = NotificationMessage(type: type, title: title)
            self.messages.append(message)
            self.saveMessages()
        }
    }

    func clearMessages() {
        DispatchQueue.main.async {
            self.messages.removeAll()
            self.saveMessages()
        }
    }

    func removeMessage(_ message: NotificationMessage) {
        DispatchQueue.main.async {
            self.messages.removeAll { $0.id == message.id }
            self.saveMessages()
        }
    }

    // MARK: - Persistence

    private func saveMessages() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        if let encoded = try? encoder.encode(messages) {
            UserDefaults.standard.set(encoded, forKey: messagesKey)
        }
    }

    private func loadPersistedMessages() {
        guard let data = UserDefaults.standard.data(forKey: messagesKey) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let decoded = try? decoder.decode([NotificationMessage].self, from: data) {
            messages = decoded
        }
    }
}

// Make NotificationMessage conform to Codable for persistence
extension NotificationMessage: Codable {
    enum CodingKeys: String, CodingKey {
        case type, title, timestamp
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(title, forKey: .title)
        try container.encode(timestamp, forKey: .timestamp)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(NotificationType.self, forKey: .type)
        self.title = try container.decode(String.self, forKey: .title)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
    }
}

extension NotificationType: Codable {}
