import SwiftUI
import UniformTypeIdentifiers

struct AddMusicSheet: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @Environment(\.dismiss)
    private var dismiss
    @State private var choosingFiles = false
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose audio files to copy into Petrichor. The originals stay where they are.")
                    Button("Choose Files") { choosingFiles = true }
                        .disabled(importing)
                    if importing { ProgressView("Adding music…") }
                    if let message { Text(message).foregroundStyle(.secondary) }
                }
                Section("Import a Folder") {
                    Text("In Files, copy your music folder to On My iPhone → Petrichor. Return here and the library will update automatically.")
                }
            }
            .navigationTitle("Add Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(importing)
                }
            }
            .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): importFiles(urls)
                case .failure: message = String(localized: "Unable to read the selected files. Try again.")
                }
            }
        }
        .interactiveDismissDisabled(importing)
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importing = true
        message = nil
        Task {
            do {
                let skipped = try await libraryManager.importMusicFiles(urls)
                if skipped == urls.count {
                    message = String(localized: "No files were added. Choose supported audio files and check available storage.")
                } else {
                    message = skipped == 0
                        ? String(localized: "Files copied to Petrichor.")
                        : String(localized: "Some files could not be copied. The remaining files are in Petrichor.")
                }
            } catch {
                message = String(localized: "Unable to add music. Check the files and available storage, then try again.")
                Logger.error("Music import failed: \(error)")
            }
            importing = false
        }
    }
}
