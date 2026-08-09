import SwiftUI

// `NotificationType`, `NotificationMessage`, `NotificationManager` moved to
// `Managers/NotificationManager.swift` — both platforms' scan/playback code
// posts through the manager, so it can't live in a macOS-only Views file.
// This file keeps only the tray UI that renders it.

// MARK: - Notification Tray View

struct NotificationTray: View {
    @StateObject private var manager = NotificationManager.shared
    @State private var showingPopover = false
    @State private var isHovered = false
    @State private var showingActivity = false
    
    var body: some View {
        Button(action: {
            if hasNotifications || manager.isActivityInProgress {
                showingPopover.toggle()
            }
        }, label: {
            ZStack {
                // Background circle only on hover
                if isHovered {
                    Circle()
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: 24, height: 24)
                        .animation(.easeInOut(duration: 0.1), value: isHovered)
                }
                
                if showingActivity {
                    // Activity indicator
                    ActivityAnimation(size: .small)
                } else if hasNotifications {
                    // Notification icon
                    Image(systemName: mostSevereNotificationType.icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(mostSevereNotificationType.color)
                        .frame(width: 24, height: 24)
                }
            }
        })
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            NotificationPopover(isPresented: $showingPopover)
        }
        .help(tooltipText)
        .onHover { hovering in
            isHovered = hovering
        }
        .onChange(of: manager.isActivityInProgress) { _, newValue in
            if newValue {
                showingActivity = true
            } else {
                // Delay hiding activity to prevent flicker
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showingActivity = false
                }
            }
        }
        .transition(.scale.combined(with: .opacity))
    }
    
    // MARK: - Computed Properties
    
    private var hasNotifications: Bool {
        !manager.messages.isEmpty
    }
    
    private var mostSevereNotificationType: NotificationType {
        if manager.messages.contains(where: { $0.type == .error }) {
            return .error
        } else if manager.messages.contains(where: { $0.type == .warning }) {
            return .warning
        }
        return .info
    }
    
    private var tooltipText: String {
        if manager.isActivityInProgress {
            return manager.activityMessage.isEmpty ? String(localized: "Refreshing Library...") : manager.activityMessage
        } else if hasNotifications {
            return String(localized: "\(manager.messages.count) notifications")
        }
        return ""
    }
}

// MARK: - Notification Popover

struct NotificationPopover: View {
    @StateObject private var manager = NotificationManager.shared
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                (manager.isActivityInProgress ? Text("Updating Library") : Text("Notifications"))
                    .font(.headline)
                
                Spacer()
                
                if !manager.messages.isEmpty && !manager.isActivityInProgress {
                    Button("Clear") {
                        manager.clearMessages()
                        isPresented = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Clear all notifications")
                }
            }
            .padding(10)
            
            Divider()
            
            // Content
            if manager.isActivityInProgress {
                scanProgressView
            } else if manager.messages.isEmpty {
                emptyState
            } else {
                messagesList
            }
        }
        .frame(width: 350)
        .frame(maxHeight: 400)
    }
    
    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            
            Text("No notifications")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    @ViewBuilder private var messagesList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(manager.messages.reversed()) { message in
                    NotificationRow(message: message) {
                        manager.removeMessage(message)
                    }
                    
                    if message.id != manager.messages.first?.id {
                        Divider()
                            .padding(.horizontal)
                    }
                }
            }
        }
    }
    
    @ViewBuilder private var scanProgressView: some View {
        VStack(spacing: 16) {
            ActivityAnimation(size: .medium)
            
            VStack(spacing: 8) {
                (manager.activityMessage.isEmpty ? Text("Processing...") : Text(manager.activityMessage))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                
                if let progress = manager.activityProgress {
                    if let detail = progress.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    if progress.total > 0 {
                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 250)
                    }
                }
            }
            
            if manager.activityProgress != nil {
                Text("You can continue using the app while this completes")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
    }
}

// MARK: - Notification Row

struct NotificationRow: View {
    let message: NotificationMessage
    let onDismiss: () -> Void
    
    @State private var isHovered = false
    
    private var timeAgoText: String {
        let now = Date()
        let interval = now.timeIntervalSince(message.timestamp)

        if interval < 60 {
            return String(localized: "Just now")
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: message.timestamp, relativeTo: now)
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: message.type.icon)
                .font(.system(size: 14))
                .foregroundColor(message.type.color)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(message.title)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                
                Text(timeAgoText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            if isHovered {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(isHovered ? Color.secondary.opacity(0.1) : Color.clear)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Preview

// swiftlint:disable localized_notification_message - preview-only sample data, not shipped UI
#Preview {
    VStack(spacing: 40) {
        // Activity in progress
        NotificationTray()
            .onAppear {
                NotificationManager.shared.startActivity("Scanning for new music...")
            }

        // With notifications
        NotificationTray()
            .onAppear {
                NotificationManager.shared.stopActivity()
                NotificationManager.shared.addMessage(.info, "2 folders refreshed for changes")
                NotificationManager.shared.addMessage(.warning, "1 folder couldn't be accessed")
                NotificationManager.shared.addMessage(.error, "Failed to scan Downloads folder")
            }
    }
    .padding()
}
// swiftlint:enable localized_notification_message
