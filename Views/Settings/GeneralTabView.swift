import SwiftUI
#if os(macOS)
#endif

struct GeneralTabView: View {
    @EnvironmentObject var libraryManager: LibraryManager

    @AppStorage("startAtLogin")
    private var startAtLogin = false

    @AppStorage("closeToMenubar")
    private var closeToMenubar = true

    @AppStorage("hideDuplicateTracks")
    private var hideDuplicateTracks: Bool = true


    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Start at login", isOn: $startAtLogin)
                    .help("Starts app on login")
                Toggle("Keep running in menubar on close", isOn: $closeToMenubar)
                    .help("Keeps the app running in the menubar even after closing")
                Toggle("Hide duplicate songs", isOn: $hideDuplicateTracks)
                    .help("Shows only the highest quality version in the library; explicit playlist entries remain visible")
                    .onChange(of: hideDuplicateTracks) {
                        // Filter is applied at query time; invalidate the load-once caches
                        // and reload affected state so it takes effect without a relaunch.
                        Logger.info("Hide duplicate songs setting changed to \(hideDuplicateTracks), refreshing library")
                        UserDefaults.standard.synchronize()
                        libraryManager.reloadForDuplicateVisibilityChange()
                    }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .padding(5)
    }
}

#Preview {
    GeneralTabView()
        .frame(width: 600, height: 500)
        .environmentObject(LibraryManager())
}
