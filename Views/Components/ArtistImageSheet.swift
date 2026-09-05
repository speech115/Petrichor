import SwiftUI

struct ArtistImageSheet: View {
    let artistName: String
    let artistId: Int64?
    @Binding var isPresented: Bool
    var onImageSelected: ((Data?) -> Void)?

    @State private var searchQuery: String
    @State private var imageURL = ""
    @State private var images: [ArtistBioManager.ImageResult] = []
    @State private var selectedIndex: Int?
    @State private var artworkData: Data?
    @State private var artworkURL = ""
    @State private var artworkSource = "manual"
    @State private var isSearching = false
    @State private var isLoadingURL = false
    @State private var isProcessingArtwork = false
    @State private var isSaving = false
    @State private var isDeletingImage = false
    @State private var searchTask: Task<Void, Never>?
    @State private var artworkTask: Task<Void, Never>?
    @State private var artworkGeneration = 0
    @State private var wellInvalidationToken = 0

    init(
        artistName: String,
        artistId: Int64?,
        isPresented: Binding<Bool>,
        onImageSelected: ((Data?) -> Void)? = nil
    ) {
        self.artistName = artistName
        self.artistId = artistId
        _isPresented = isPresented
        self.onImageSelected = onImageSelected
        _searchQuery = State(initialValue: artistName)
    }

    private var canSave: Bool {
        (artworkData != nil || isDeletingImage) && !isProcessingArtwork && !isLoadingURL && !isSaving
    }

    var body: some View {
        VStack(spacing: 0) {
            PlaylistEditorHeader(title: String(localized: "Choose Artist Image")) {
                guard !isSaving else { return }
                isPresented = false
            }

            Divider()

            artworkSection

            Divider()

            searchSection

            Divider()
            footer
        }
        .frame(width: 540, height: 620)
        .task {
            let generation = artworkGeneration
            await loadCurrentImage(generation: generation)
            startImageSearch()
        }
        .onDisappear {
            searchTask?.cancel()
            artworkTask?.cancel()
        }
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkInputField(
                text: $searchQuery,
                placeholder: "Search artist images",
                leadingIcon: Icons.magnifyingGlass,
                actionIcon: "arrow.right.circle.fill",
                actionHelp: "Search",
                isActionEnabled: !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty,
                isLoading: isSearching,
                action: startImageSearch
            )

            imageResults
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var imageResults: some View {
        if images.isEmpty, !isSearching {
            Text("No images available")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !images.isEmpty {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 116), spacing: 10)], spacing: 10) {
                    ForEach(Array(images.enumerated()), id: \.offset) { index, result in
                        imageCell(result: result, index: index)
                    }
                }
                .padding(3)
            }
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func imageCell(result: ArtistBioManager.ImageResult, index: Int) -> some View {
        let isSelected = selectedIndex == index

        return Group {
            if let platformImage = PlatformImage(data: result.imageData) {
                Image(platformImage: platformImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 108, height: 108)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(selectedIndex == index ? Color.accentColor : .clear, lineWidth: 3)
                    )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            supersedeAllArtworkOperations()
            selectedIndex = index
            artworkData = result.imageData
            artworkURL = result.imageUrl
            artworkSource = result.source.components(separatedBy: " – ").first ?? result.source
            isDeletingImage = false
        }
    }

    private var artworkSection: some View {
        VStack(spacing: 10) {
            ArtworkImageWell(
                artworkData: $artworkData,
                isProcessing: $isProcessingArtwork,
                placeholderIcon: Icons.personFill,
                onImported: markManualImport,
                onClear: markImageForDeletion,
                maxDimension: 960,
                onArtworkAction: cancelParentArtworkOperation,
                invalidationToken: wellInvalidationToken
            )

            ArtworkInputField(
                text: $imageURL,
                placeholder: "Load image from URL",
                leadingIcon: "link",
                actionIcon: Icons.arrowDownCircleFill,
                actionHelp: "Load Image",
                isActionEnabled: parsedImageURL != nil,
                isLoading: isLoadingURL,
                action: startURLLoad
            )
            .frame(width: 460)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Button {
                deleteImage()
            } label: {
                Text("Delete Image").foregroundColor(.red)
            }
            .disabled(artistId == nil || isSaving)

            Spacer()

            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)

            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding()
    }

    private var parsedImageURL: URL? {
        ArtworkImageLoader.httpURL(from: imageURL)
    }

    private var libraryManager: LibraryManager? {
        AppCoordinator.shared?.libraryManager
    }

    private func saveArtistImage(_ imageData: Data, url: String, source: String) {
        guard let artistId, let libraryManager else { return }

        libraryManager.updateArtistInfo(
            artistId: artistId,
            imageData: imageData,
            imageUrl: url,
            imageSource: source
        )
        onImageSelected?(imageData)
        libraryManager.updateArtistEntityArtwork(name: artistName, artworkData: imageData)
    }

    private var sheetFooter: some View {
        HStack {
            Button {
                guard let artistId, let libraryManager else { return }
                libraryManager.deleteArtistImage(artistId: artistId)
                onImageSelected?(nil)
                libraryManager.updateArtistEntityArtwork(name: artistName, artworkData: nil)
                isPresented = false
            }
        }
    }

    private func cancelParentArtworkOperation() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkGeneration += 1
        isLoadingURL = false
    }

    private func downloadImage(from url: URL) async -> [ArtistBioManager.ImageResult] {
        // Cap download size at 50 MB to prevent a potential memory overload
        // if image URL points an unusually large image.
        let maxBytes: Int64 = 50 * 1024 * 1024

        do {
            var request = URLRequest(url: url)
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

            let (bytes, response) = try await AppInfo.urlSession.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                Logger.error("Failed to download image from URL: \(url)")
                return []
            }

            // Reject when size is over the limit
            if response.expectedContentLength > maxBytes {
                Logger.error("Image size is too large: \(response.expectedContentLength) > \(maxBytes)")
                return []
            }

            var data = Data()
            if response.expectedContentLength > 0 {
                data.reserveCapacity(Int(response.expectedContentLength))
            }
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes {
                    Logger.error("Image size is too large: \(response.expectedContentLength) > \(maxBytes)")
                    return []
                }
            }

            guard !data.isEmpty, PlatformImage(data: data) != nil else {
                Logger.error("Image is empty or invalid: \(response.expectedContentLength)")
                return []
            }
            
            return [ArtistBioManager.ImageResult(imageData: data, imageUrl: url.absoluteString, source: "url")]
        } catch {
            return []
        }
    }
}
