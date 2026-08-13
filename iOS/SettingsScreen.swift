//
// SettingsScreen (iOS)
//
// iPhone settings: exactly what the design spec lists — rescan the library,
// lyrics and artist info toggles, color scheme with artwork tinting, hiding
// duplicate tracks, and About. Equalizer, scrobbling, scheduled auto-scan and
// technical track details are macOS-only and intentionally absent.
//
// The rescan reuses `LibraryManager.scanLibraryRoot()`: it runs on a utility
// task, publishes progress through `NotificationManager`, and survives leaving
// the screen — an interrupted scan resumes from where it stopped on the next
// launch because already-imported tracks are matched by path.
//

import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var libraryManager: LibraryManager

    @AppStorage("onlineLyricsEnabled")
    private var onlineLyricsEnabled = false

    @AppStorage("artistInfoFetchEnabled")
    private var artistInfoFetchEnabled = false

    @AppStorage("hideDuplicateTracks")
    private var hideDuplicateTracks = true

    @AppStorage("colorMode")
    private var colorMode: ColorMode = .auto

    @AppStorage("useArtworkColors")
    private var useArtworkColors = true

    @StateObject private var notificationManager = NotificationManager.shared

    var body: some View {
        Form {
            librarySection
            musicSection
            appearanceSection
            aboutSection
        }
        .navigationTitle(String(localized: "Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: colorMode) { _, newValue in
            newValue.apply()
        }
        .onAppear {
            colorMode.apply()
        }
    }

    // MARK: - Library

    /// The system section-header gray sits at ~3.3:1 against the grouped
    /// background in light mode, below the 4.5:1 the accessibility gate
    /// demands, so every header here uses the shared accessible secondary
    /// color instead of the default.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .foregroundColor(.secondaryText)
    }

    private var librarySection: some View {
        Section {
            Button {
                rescanLibrary()
            } label: {
                Label(String(localized: "Rescan Library"), systemImage: Icons.arrowClockwise)
            }
            .disabled(libraryManager.isScanning)

            if libraryManager.isScanning, let progress = notificationManager.activityProgress {
                rescanProgress(progress)
            }
        } header: {
            sectionHeader(String(localized: "Library"))
        }
    }

    @ViewBuilder
    private func rescanProgress(_ progress: NotificationManager.ActivityProgress) -> some View {
        if progress.total > 0 {
            ProgressView(value: progress.fraction)
        } else {
            ProgressView()
        }
        if let detail = progress.detail {
            Text(detail)
                .font(.footnote)
                .foregroundColor(.secondaryText)
        }
    }

    private func rescanLibrary() {
        guard !libraryManager.isScanning else { return }
        Task {
            do {
                try await libraryManager.scanLibraryRoot()
            } catch {
                Logger.error("Failed to rescan the library: \(error)")
                NotificationManager.shared.addMessage(.error, String(localized: "Failed to rescan the library"))
            }
        }
    }

    // MARK: - Music

    private var musicSection: some View {
        Section {
            Toggle(String(localized: "Hide duplicate songs"), isOn: $hideDuplicateTracks)
                .onChange(of: hideDuplicateTracks) { _, _ in
                    libraryManager.reloadForDuplicateVisibilityChange()
                }

            Toggle(String(localized: "Fetch lyrics from the internet"), isOn: $onlineLyricsEnabled)

            Toggle(String(localized: "Fetch artist photos and bios from the internet"), isOn: $artistInfoFetchEnabled)
                .onChange(of: artistInfoFetchEnabled) { _, enabled in
                    if enabled {
                        ArtistBioManager.shared.fetchMissingArtistImages(using: libraryManager)
                    }
                }
        } header: {
            sectionHeader(String(localized: "Music"))
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            Picker(String(localized: "Color Scheme"), selection: $colorMode) {
                ForEach(ColorMode.allCases, id: \.self) { mode in
                    Label(mode.displayName, systemImage: mode.icon)
                        .tag(mode)
                }
            }

            Toggle(String(localized: "Tint interface with album artwork colors"), isOn: $useArtworkColors)
        } header: {
            sectionHeader(String(localized: "Appearance"))
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: Icons.musicNote)
                    // Settings follow Dynamic Type without a ceiling: the
                    // icon is a large-title glyph and the tile grows with it.
                    .font(.largeTitle.weight(.light))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 60, minHeight: 60)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 2) {
                    Text(About.appTitle)
                        .font(.headline)
                    Text(AppInfo.versionWithBuild)
                        .font(.subheadline)
                        .foregroundColor(.secondaryText)
                }
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Petrichor for iPhone — a port of the macOS music player."))
                Text(String(localized: "A fork of kushalpandya/Petrichor, MIT License © Kushal Pandya."))
                    .font(.footnote)
                    .foregroundColor(.secondaryText)
            }
            .padding(.vertical, 4)

            if let url = URL(string: About.appRepository) {
                Link(destination: url) {
                    Label(String(localized: "Source Repository"), systemImage: Icons.globe)
                }
            }
        } header: {
            sectionHeader(String(localized: "About"))
        }
    }
}
