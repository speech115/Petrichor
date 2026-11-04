//
// DatabaseUnavailableView (iOS)
//
// Shown instead of the tabs when the library database does not open (see
// `AppLaunch`). Retrying covers a passing cause such as a full disk; a
// damaged file needs the reset, which asks first because it drops what only
// the database holds.
//

import SwiftUI

struct DatabaseUnavailableView: View {
    @ObservedObject var launch: AppLaunch<AppCoordinator>
    @State private var showingResetConfirmation = false

    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "Library Unavailable"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(launch.databaseError ?? "")
                .foregroundStyle(Color.secondaryText)
        } actions: {
            Button(String(localized: "Try Again")) { launch.openLibrary() }
                .buttonStyle(.borderedProminent)
            Button(String(localized: "Reset Library…"), role: .destructive) {
                showingResetConfirmation = true
            }
        }
        .alert(String(localized: "Reset Library"), isPresented: $showingResetConfirmation) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Reset"), role: .destructive) { launch.resetLibraryDatabase() }
        } message: {
            Text(String(
                localized: "Music files stay on the iPhone and are scanned again. Playlists, favorites and play counts are deleted."
            ))
        }
    }
}
