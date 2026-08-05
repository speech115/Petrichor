//
// FoldersTabView (iOS)
//
// Root of the Folders tab: the watched folders as the top of the tree, each
// with its track count, pushing into the tab's NavigationStack. The same
// folder row is reused at every level of the hierarchy, so the tree reads
// exactly as it lies on disk. Adding a folder from Files lives in the
// navigation bar.
//

import SwiftUI

struct FoldersTabView: View {
    @EnvironmentObject private var libraryManager: LibraryManager

    @Binding var showingFileImporter: Bool

    @State private var folderNodes: [FolderNode] = []
    @State private var isLoadingHierarchy = false

    private let hierarchyBuilder = FolderHierarchyBuilder()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(String(localized: "Folders"))
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: FolderNode.self) { node in
                    FolderDetailView(node: node)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingFileImporter = true
                        } label: {
                            Image(systemName: Icons.folderBadgePlus)
                        }
                        .accessibilityLabel(String(localized: "Add Folder"))
                    }
                }
        }
        .task {
            await loadFolderHierarchy()
        }
        .onChange(of: libraryManager.folders) { _, _ in
            Task {
                await loadFolderHierarchy()
            }
        }
    }

    @ViewBuilder private var content: some View {
        if isLoadingHierarchy {
            ProgressView()
        } else if folderNodes.isEmpty {
            ContentUnavailableView(
                String(localized: "No Folders"),
                systemImage: Icons.folder,
                description: Text(String(localized: "Add a music folder to get started"))
            )
        } else {
            folderList
        }
    }

    private var folderList: some View {
        List(folderNodes) { node in
            NavigationLink(value: node) {
                FolderRowView(node: node)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func loadFolderHierarchy() async {
        await MainActor.run {
            isLoadingHierarchy = true
        }

        let trackCounts = libraryManager.getTrackCountsByFolderPath()
        let nodes = await hierarchyBuilder.buildHierarchy(
            for: libraryManager.folders,
            trackCountsByFolder: trackCounts
        )

        await MainActor.run {
            folderNodes = nodes
            isLoadingHierarchy = false
        }
    }
}
