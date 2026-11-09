import AppKit
import SwiftUI

/// The left sidebar's backdrop, as in the system's own sidebars: translucent,
/// showing the desktop and windows behind it. On macOS 26 it is a floating
/// Liquid Glass pane inset from the window edges, as in the Music app and
/// Finder; earlier systems get the classic full-height sidebar vibrancy.
enum SidebarGlass {
    static let inset: CGFloat = 8
    static let cornerRadius: CGFloat = 16

    static var isFloating: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

extension View {
    @ViewBuilder
    func sidebarGlass() -> some View {
        if #available(macOS 26.0, *) {
            let shape = RoundedRectangle(cornerRadius: SidebarGlass.cornerRadius, style: .continuous)
            self
                .clipShape(shape)
                .background(BehindWindowSidebarMaterial().clipShape(shape))
                .glassEffect(.clear, in: shape)
                .padding(SidebarGlass.inset)
        } else {
            background(BehindWindowSidebarMaterial().ignoresSafeArea())
        }
    }
}

/// The system sidebar material, blended with what is behind the window and
/// following the window's key state like Finder's sidebar.
private struct BehindWindowSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
