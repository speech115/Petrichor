import AppKit
import SwiftUI

/// The left sidebar's backdrop, as in the system's own sidebars: the sidebar
/// material blended with the desktop and windows behind the window. On
/// macOS 26 it is a floating pane inset from the window edges, as in the
/// Music app and Finder; earlier systems get the classic full-height sidebar.
/// No SwiftUI `glassEffect` on top: it samples only the window's own content,
/// cannot see through the behind-window material and renders it opaque.
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
            // The pane runs up to the window's top edge, so the window buttons
            // sit inside it; the list itself stays below them.
            self
                .padding([.horizontal, .bottom], SidebarGlass.inset)
                .background {
                    BehindWindowSidebarMaterial()
                        .clipShape(shape)
                        .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                        .padding(SidebarGlass.inset)
                        .ignoresSafeArea(.container, edges: .top)
                }
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
