import Foundation
import Testing
@testable import Musify

@Test func storedPathIsRelativeToLibraryRoot() {
    let url = LibraryPathStore.libraryRoot
        .appendingPathComponent("Моя музыка/Spotify/0239 - Jeune Ras.mp3")

    #expect(LibraryPathStore.storedPath(for: url) == "Моя музыка/Spotify/0239 - Jeune Ras.mp3")
}

@Test func storedPathRoundTripsBackToTheSameURL() {
    let url = LibraryPathStore.libraryRoot
        .appendingPathComponent("Моя музыка/ВКонтакте/track.mp3")

    let restored = LibraryPathStore.url(fromStored: LibraryPathStore.storedPath(for: url))

    #expect(restored.standardizedFileURL == url.standardizedFileURL)
}

@Test func storedPathSurvivesAChangedContainerUUID() {
    // Хранимый путь не должен содержать ничего от контейнера.
    let url = LibraryPathStore.libraryRoot.appendingPathComponent("Моя музыка/track.mp3")
    let stored = LibraryPathStore.storedPath(for: url)

    #expect(!stored.contains("/var/mobile"))
    #expect(!stored.hasPrefix("/"))
}

@Test func urlOutsideLibraryRootIsStoredAbsolutely() {
    let outside = URL(fileURLWithPath: "/tmp/somewhere/track.mp3")

    #expect(LibraryPathStore.storedPath(for: outside) == "/tmp/somewhere/track.mp3")
}

@Test func libraryRootItselfStoresAsAnEmptyRelativePath() {
    // Registering the library root as a Folder (the iOS scan entry point does
    // exactly this) must not fall through to the "outside the root" branch and
    // write an absolute, container-specific path.
    let stored = LibraryPathStore.storedPath(for: LibraryPathStore.libraryRoot)

    #expect(stored == "")
    #expect(LibraryPathStore.url(fromStored: stored).standardizedFileURL == LibraryPathStore.libraryRoot.standardizedFileURL)
}
