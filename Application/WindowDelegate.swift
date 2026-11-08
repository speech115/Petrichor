//
// WindowDelegate class
//
// Closing the main window hides it instead of destroying it, like Music.app:
// the app keeps running (and playing) in the Dock, and clicking the Dock icon
// brings the same window back.
//

import AppKit

class WindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Save playback state when window closes
        AppCoordinator.shared?.savePlaybackState()
        sender.orderOut(nil)
        return false
    }
}
