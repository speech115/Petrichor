//
// MediaLibraryView (iOS)
//
// Root of the Media tab: the five category entries — Artists, Albums,
// Genres, Years, All Tracks — each pushing into the tab's NavigationStack.
// Settings live in the navigation bar. Discover lives on Home, not here
// (the design spec's Media tab is categories only).
//

import SwiftUI

struct MediaLibraryView: View {
    @EnvironmentObject private var libraryManager: LibraryManager

    @Binding var path: [LibraryDestination]
    @Binding var showingSettings: Bool

    var body: some View {
        NavigationStack(path: $path) {
            categoryList
                .navigationDestination(for: LibraryDestination.self) { destination in
                    destinationView(destination)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: Icons.settings)
                        }
                        .accessibilityLabel(String(localized: "Settings"))
                    }
                }
        }
    }

    private var categoryList: some View {
        List {
            Section {
                NavigationLink(value: LibraryDestination.category(.artists)) {
                    categoryRow(LibraryFilterType.artists)
                }
                NavigationLink(value: LibraryDestination.category(.albums)) {
                    categoryRow(LibraryFilterType.albums)
                }
                NavigationLink(value: LibraryDestination.category(.genres)) {
                    categoryRow(LibraryFilterType.genres)
                }
                NavigationLink(value: LibraryDestination.category(.years)) {
                    categoryRow(LibraryFilterType.years)
                }
                NavigationLink(value: LibraryDestination.allTracks) {
                    HStack(spacing: 12) {
                        Image(systemName: Icons.musicNote)
                            .foregroundColor(.accentColor)
                        Text(String(localized: "All Tracks"))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "Media"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if !libraryManager.shouldShowMainUI {
                ContentUnavailableView(
                    String(localized: "No Music"),
                    systemImage: Icons.musicNote,
                    description: Text(String(localized: "Add a music folder to get started"))
                )
            }
        }
    }

    private func categoryRow(_ type: LibraryFilterType) -> some View {
        HStack(spacing: 12) {
            SymbolImage(type.icon)
                .foregroundColor(.accentColor)
            Text(type.pluralDisplayName)
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: LibraryDestination) -> some View {
        switch destination {
        case .discover:
            DiscoverView()
        case .category(let filterType):
            CategoryItemsView(filterType: filterType)
        case .tracks(let item):
            TrackListView(filterItem: item)
        case .allTracks:
            TrackListView(filterItem: nil)
        case .artist(let name):
            ArtistPage(artistName: name)
        case .album(let album):
            AlbumPage(album: album)
        }
    }
}
