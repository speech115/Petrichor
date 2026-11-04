import Foundation
import Testing
@testable import Petrichor

/// `ArtistParser.parse` splits a tag into the artists a track is linked to;
/// the first name is the primary artist (album grouping, `position` 0), so
/// order is part of the contract.
///
/// `role: nil` parses with no name lookup, which is the state of every
/// library without a bundled known-artists file: ambiguous separators are
/// split blindly and bare "/" is kept. The lookup cases install their own
/// names under a role no production code uses.
@Suite(.serialized)
struct ArtistParserTests {
    // MARK: - Without a name lookup

    @Test(arguments: [
        ("Drake feat. Rihanna", ["Drake", "Rihanna"]),
        ("Drake feat Rihanna", ["Drake", "Rihanna"]),
        ("Drake featuring Rihanna", ["Drake", "Rihanna"]),
        ("Drake ft. Rihanna", ["Drake", "Rihanna"]),
        ("Drake ft Rihanna", ["Drake", "Rihanna"]),
        ("Drake Feat. Rihanna", ["Drake", "Rihanna"]),
        ("Drake;Rihanna", ["Drake", "Rihanna"]),
        ("宇多田ヒカル、椎名林檎", ["宇多田ヒカル", "椎名林檎"]),
        ("Kanye West & Jay-Z", ["Kanye West", "Jay-Z"]),
        ("Kanye West and Jay-Z", ["Kanye West", "Jay-Z"]),
        ("Kanye West x Lil Pump", ["Kanye West", "Lil Pump"]),
        ("Kanye West X Lil Pump", ["Kanye West", "Lil Pump"]),
        ("Daft Punk vs. Jay-Z", ["Daft Punk", "Jay-Z"]),
        ("Daft Punk vs Jay-Z", ["Daft Punk", "Jay-Z"]),
        ("Daft Punk, Jay-Z, Pharrell", ["Daft Punk", "Jay-Z", "Pharrell"]),
        ("Daft Punk with Jay-Z", ["Daft Punk", "Jay-Z"]),
        ("Daft Punk / Jay-Z", ["Daft Punk", "Jay-Z"]),
        ("Daft Punk／Jay-Z", ["Daft Punk", "Jay-Z"])
    ])
    func splitsOnEverySeparatorInTagOrder(tag: String, expected: [String]) {
        #expect(ArtistParser.parse(tag, role: nil) == expected)
    }

    @Test func keepsTheOrderOfManyArtists() {
        // Unordered de-duplication used to return these in dictionary order,
        // which changes per launch and moved the primary artist around.
        let tag = "Zemfira feat. Ayo, Basta & Charli XCX x Dua Lipa; Eminem"
        #expect(ArtistParser.parse(tag, role: nil) == ["Zemfira", "Ayo", "Basta", "Charli XCX", "Dua Lipa", "Eminem"])
    }

    @Test func splitsCyrillicNames() {
        #expect(ArtistParser.parse("Кино & Земфира", role: nil) == ["Кино", "Земфира"])
        #expect(ArtistParser.parse("Сплин feat. Би-2", role: nil) == ["Сплин", "Би-2"])
        #expect(ArtistParser.parse("Баста, Скриптонит", role: nil) == ["Баста", "Скриптонит"])
        #expect(ArtistParser.parse("Мумий Тролль", role: nil) == ["Мумий Тролль"])
    }

    @Test func keepsBareSlashAndSeparatorFreeNames() {
        #expect(ArtistParser.parse("AC/DC", role: nil) == ["AC/DC"])
        #expect(ArtistParser.parse("Lil Nas X", role: nil) == ["Lil Nas X"])
        #expect(ArtistParser.parse("Lil Nas X feat. Billy Ray Cyrus", role: nil) == ["Lil Nas X", "Billy Ray Cyrus"])
        #expect(ArtistParser.parse("Joe Andrews", role: nil) == ["Joe Andrews"])
    }

    @Test func splitsNamesContainingSeparatorsWhenNothingSaysTheyAreOneArtist() {
        // Documented limit of the lookup-free mode, kept so a change to it is deliberate.
        #expect(ArtistParser.parse("Mumford & Sons", role: nil) == ["Mumford", "Sons"])
        #expect(ArtistParser.parse("Tyler, The Creator", role: nil) == ["Tyler", "The Creator"])
    }

    @Test func emptyAndPlaceholderTagsBecomeThePlaceholder() {
        #expect(ArtistParser.parse("", role: nil) == ["Unknown Artist"])
        #expect(ArtistParser.parse("   ", role: nil) == ["Unknown Artist"])
        #expect(ArtistParser.parse("", unknownPlaceholder: "Unknown Composer", role: nil) == ["Unknown Composer"])
        #expect(ArtistParser.parse("Unknown Artist & Rihanna", role: nil) == ["Rihanna"])
        #expect(ArtistParser.parse("Drake & ", role: nil) == ["Drake"])
        #expect(ArtistParser.parse(" & ", role: nil) == ["Unknown Artist"])
    }

    @Test func trimsAndDeduplicatesKeepingTheFirstPositionAndTheLongerSpelling() {
        #expect(ArtistParser.parse("  Drake  &  Rihanna  ", role: nil) == ["Drake", "Rihanna"])
        #expect(ArtistParser.parse("Drake & drake", role: nil) == ["Drake"])
        #expect(ArtistParser.parse("J Cole & Kendrick Lamar & J. Cole", role: nil) == ["J. Cole", "Kendrick Lamar"])
    }

    // MARK: - Normalization

    @Test func normalizationFoldsCaseInitialsHyphensAndSpaces() {
        #expect(ArtistParser.normalizeArtistName("J. Cole") == ArtistParser.normalizeArtistName("J Cole"))
        #expect(ArtistParser.normalizeArtistName("Jay - Z") == "jay-z")
        #expect(ArtistParser.normalizeArtistName("Jay -Z") == "jay-z")
        #expect(ArtistParser.normalizeArtistName("  Daft    Punk ") == "daft punk")
        #expect(ArtistParser.normalizeArtistName("ЗЕМФИРА") == "земфира")
        #expect(ArtistParser.normalizeArtistName("Би - 2") == "би-2")
    }

    // MARK: - With library names

    private static let role = "artist-parser-tests"

    private func withLibraryNames(_ names: [String: String], _ body: () -> Void) {
        ArtistParser.setLibraryArtists([Self.role: names])
        defer { ArtistParser.setLibraryArtists([:]) }
        body()
    }

    @Test func knownNamesWithSeparatorsStayWhole() {
        withLibraryNames([
            "mumford & sons": "Mumford & Sons",
            "tyler, the creator": "Tyler, The Creator",
            "simon & garfunkel": "Simon & Garfunkel",
            "ac/dc": "AC/DC"
        ]) {
            #expect(ArtistParser.parse("Mumford & Sons", role: Self.role) == ["Mumford & Sons"])
            #expect(ArtistParser.parse("Tyler, The Creator & Kali Uchis", role: Self.role) == ["Tyler, The Creator", "Kali Uchis"])
            #expect(ArtistParser.parse("Simon & Garfunkel feat. Mumford & Sons", role: Self.role) == ["Simon & Garfunkel", "Mumford & Sons"])
            #expect(ArtistParser.parse("AC/DC/Mumford & Sons", role: Self.role) == ["AC/DC", "Mumford & Sons"])
        }
    }

    @Test func aLookupStillSplitsUnknownNamesAndBareSlash() {
        withLibraryNames(["mumford & sons": "Mumford & Sons"]) {
            #expect(ArtistParser.parse("Drake & Rihanna", role: Self.role) == ["Drake", "Rihanna"])
            #expect(ArtistParser.parse("Drake/Rihanna", role: Self.role) == ["Drake", "Rihanna"])
            #expect(ArtistParser.parse("Daft Punk vs. Jay-Z", role: Self.role) == ["Daft Punk", "Jay-Z"])
            #expect(ArtistParser.parse("Кино & Земфира", role: Self.role) == ["Кино", "Земфира"])
        }
    }

    @Test func mergedAwayNamesResolveToTheirCanonicalArtist() {
        withLibraryNames(["p!nk": "Pink", "pink": "Pink", "земфира рамазанова": "Земфира"]) {
            #expect(ArtistParser.parse("P!nk", role: Self.role) == ["Pink"])
            #expect(ArtistParser.parse("P!nk feat. Nate Ruess", role: Self.role) == ["Pink", "Nate Ruess"])
            #expect(ArtistParser.parse("Pink & P!nk", role: Self.role) == ["Pink"])
            #expect(ArtistParser.parse("Земфира Рамазанова", role: Self.role) == ["Земфира"])
        }
    }

    @Test func namesOfAnotherRoleDoNotApply() {
        withLibraryNames(["mumford & sons": "Mumford & Sons"]) {
            #expect(ArtistParser.parse("Mumford & Sons", role: TrackArtist.Role.composer) == ["Mumford", "Sons"])
        }
    }
}
