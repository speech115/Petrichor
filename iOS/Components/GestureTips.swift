//
// GestureTips (iOS)
//
// One-time TipKit hints for the gestures nothing on screen advertises:
// swiping the mini player to skip, and tapping a lyric line to play from it.
// Each tip retires for good once shown and closed, or once the gesture is
// used. UI-test launches hide them so they never cover what a test taps.
//

import SwiftUI
import TipKit

enum GestureTips {
    static func configure() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(uitestSeedFixturesLaunchArgument) {
            Tips.hideAllTipsForTesting()
        }
        #endif
        try? Tips.configure()
    }
}

struct MiniPlayerSwipeTip: Tip {
    var title: Text { Text(String(localized: "Swipe to Change Tracks")) }
    var message: Text? {
        Text(String(localized: "Swipe left or right on the player to skip, or up to open it."))
    }
    var image: Image? { Image(systemName: "hand.draw") }
}

struct LyricsTapTip: Tip {
    var title: Text { Text(String(localized: "Tap a Line")) }
    var message: Text? { Text(String(localized: "Playback jumps to that line of the song.")) }
    var image: Image? { Image(systemName: "hand.tap") }
}
