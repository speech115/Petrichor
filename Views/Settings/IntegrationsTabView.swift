import SwiftUI

struct IntegrationsTabView: View {
    @AppStorage("onlineLyricsEnabled")
    private var onlineLyricsEnabled: Bool = false

    @AppStorage("artistInfoFetchEnabled")
    private var artistInfoFetchEnabled: Bool = false

    var body: some View {
        Form {
            Section {
                onlineFeaturesSection
            } header: {
                Text("Lyrics & Metadata")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .padding(5)
    }

    // MARK: - Online Features Section

    private var onlineFeaturesSection: some View {
        Group {
            Toggle("Fetch timed lyrics from internet when not available", isOn: $onlineLyricsEnabled)
                .help("Search for synced lyrics online when no local lyrics are found, and upgrade untimed lyrics to timed when available")

            Toggle("Fetch artist image and bio from internet", isOn: $artistInfoFetchEnabled)
                .help("Automatically download artist photos and bios from online sources")
                .onChange(of: artistInfoFetchEnabled) { _, enabled in
                    if enabled, let coordinator = AppCoordinator.shared {
                        ArtistBioManager.shared.fetchMissingArtistImages(using: coordinator.libraryManager)
                    }
                }
        }
    }
}

#Preview {
    IntegrationsTabView()
        .frame(width: 600, height: 400)
}
