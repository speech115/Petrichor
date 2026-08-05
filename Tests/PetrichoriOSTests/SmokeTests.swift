import Foundation
import Testing
@testable import Petrichor

@Test func testTargetIsWiredUp() {
    #expect(Bundle.main.bundleIdentifier != nil)
}
