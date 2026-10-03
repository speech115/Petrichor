//
// ToastCenter (iOS)
//
// One short confirmation capsule for actions that otherwise leave no trace on
// screen: Play Next, Add to Queue, favorites. It floats under the status bar,
// not above the tab bar — the bar minimizes on scroll and the mini player
// sits there, so a top capsule never depends on either. Only one toast lives
// at a time; a new one replaces the old.
//
// `undo` is offered only where the inverse is exact (favorites). Queue
// actions dedupe and reorder, so undoing them would guess.
//

import SwiftUI
import UIKit

@MainActor
final class ToastCenter: ObservableObject {
    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        let systemImage: String
        let undo: (() -> Void)?
    }

    static let shared = ToastCenter()

    @Published private(set) var toast: Toast?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ message: String, systemImage: String, undo: (() -> Void)? = nil) {
        let toast = Toast(message: message, systemImage: systemImage, undo: undo)
        withAnimation(.snappy) { self.toast = toast }
        UIAccessibility.post(notification: .announcement, argument: message)

        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(undo == nil ? 2 : 4))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.snappy) { toast = nil }
    }
}

// MARK: - Actions

extension ToastCenter {
    /// Queues `track` and says so. An empty queue starts playback instead,
    /// which the mini player already shows, so that case stays silent.
    func enqueue(_ track: Track, playNext: Bool, playlistManager: PlaylistManager) {
        let wasEmpty = playlistManager.currentQueue.isEmpty
        let alreadyQueued = !playNext && playlistManager.currentQueue.contains { $0.id == track.id }
        if playNext {
            playlistManager.playNext(track)
        } else {
            playlistManager.addToQueue(track)
        }
        guard !wasEmpty else { return }

        if alreadyQueued {
            show(String(localized: "Already in Queue"), systemImage: "checkmark.circle")
        } else if playNext {
            show(String(localized: "Playing Next"), systemImage: "text.line.first.and.arrowtriangle.forward")
        } else {
            show(String(localized: "Added to Queue"), systemImage: "text.append")
        }
    }

    func toggleFavorite(_ track: Track, playlistManager: PlaylistManager) {
        let makeFavorite = !track.isFavorite
        playlistManager.toggleFavorite(for: [track], setTo: makeFavorite)
        show(
            makeFavorite
                ? String(localized: "Added to Favorites")
                : String(localized: "Removed from Favorites"),
            systemImage: makeFavorite ? Icons.starFill : Icons.star,
            undo: { playlistManager.toggleFavorite(for: [track], setTo: !makeFavorite) }
        )
    }
}

// MARK: - Host

private struct ToastHost: ViewModifier {
    let isActive: Bool
    @ObservedObject private var center = ToastCenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if isActive, let toast = center.toast {
                ToastCapsule(toast: toast) { center.dismiss() }
                    .id(toast.id)
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

private struct ToastCapsule: View {
    let toast: ToastCenter.Toast
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.systemImage)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            if let undo = toast.undo {
                Button(String(localized: "Undo")) {
                    undo()
                    onUndo()
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // The same glass as the tab bar and the system's own floating
        // capsules; it carries its own edge and depth, so no extra shadow.
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

extension View {
    /// Shows `ToastCenter` toasts over this view. Applied to the root and to
    /// the full-screen player, which covers the root; the root passes
    /// `isActive: false` while covered so one toast is never on screen twice
    /// (VoiceOver would read the hidden copy as well).
    func toastHost(isActive: Bool = true) -> some View {
        modifier(ToastHost(isActive: isActive))
    }
}
