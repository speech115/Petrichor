import Foundation
import Testing
@testable import Musify

@Test func testTargetIsWiredUp() {
    #expect(Bundle.main.bundleIdentifier != nil)
}
