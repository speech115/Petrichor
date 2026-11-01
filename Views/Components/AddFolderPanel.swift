//
// AddFolderPanel
//
// The Mac's folder picker behind every "Add Folder" control. It only picks:
// what happens to the chosen folders (bookmarks, database, rescan) is
// `LibraryManager.addFolders`, which stays free of AppKit.
//

import AppKit

@MainActor
enum AddFolderPanel {
    /// Shows the picker as a sheet on the key window and hands the chosen
    /// folders to `add`; nothing is called when the user cancels.
    static func present(then add: @escaping ([URL]) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = true
        openPanel.prompt = String(localized: "Add Music Folder")
        openPanel.message = String(localized: "Select folders containing your music files")

        guard let keyWindow = NSApp.keyWindow else {
            Logger.error("Cannot add folder: no key window available")
            return
        }

        openPanel.beginSheetModal(for: keyWindow) { response in
            guard response == .OK else { return }
            add(openPanel.urls)
        }
    }
}
