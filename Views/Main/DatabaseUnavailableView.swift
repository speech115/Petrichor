//
// DatabaseUnavailableView (macOS)
//
// Shown in the main window instead of the library when the database does not
// open (see `AppLaunch`). The Mac only retries: its database also holds the
// folder bookmarks, so resetting it is not a one-click fix here.
//

import SwiftUI

struct DatabaseUnavailableView: View {
    @ObservedObject var launch: AppLaunch<AppCoordinator>

    var body: some View {
        ContentUnavailableView {
            Label("Library Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(launch.databaseError ?? "")
        } actions: {
            Button("Try Again") { launch.openLibrary() }
                .buttonStyle(.borderedProminent)
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}
