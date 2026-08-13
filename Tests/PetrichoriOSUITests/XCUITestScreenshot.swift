//
// Shared UITest screenshot attach — CI runners occasionally time out on
// `app.screenshot()` ("Timed out while requesting screenshot"). Attachments
// are diagnostic only; never fail a green gate on them.
//

import XCTest

extension XCTestCase {
    func attachBestEffortScreenshot(of app: XCUIApplication, named name: String) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("Screenshot capture is best-effort on CI", options: options) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
