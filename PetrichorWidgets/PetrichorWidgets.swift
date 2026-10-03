//
// PetrichorWidgets (iOS extension)
//
// Control Center buttons for Petrichor: play/pause and next track, placeable
// in Control Center, on the Lock Screen and on the Action button. Buttons,
// not a play/pause toggle: a toggle would need the playing state, and the
// app has no shared container to publish it through (App Groups are not
// available with the free signing this app builds under).
//

import AppIntents
import SwiftUI
import WidgetKit

@main
struct PetrichorWidgets: WidgetBundle {
    var body: some Widget {
        PlayPauseControl()
        NextTrackControl()
    }
}

struct PlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "org.Petrichor.ios.widgets.play-pause") {
            ControlWidgetButton(action: PlayPauseControlIntent()) {
                Label(String(localized: "Play/Pause"), systemImage: "playpause.fill")
            }
        }
        .displayName("Play/Pause")
        .description("Plays or pauses Petrichor.")
    }
}

struct NextTrackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "org.Petrichor.ios.widgets.next-track") {
            ControlWidgetButton(action: NextTrackControlIntent()) {
                Label(String(localized: "Next Track"), systemImage: "forward.fill")
            }
        }
        .displayName("Next Track")
        .description("Skips to the next song in Petrichor.")
    }
}
