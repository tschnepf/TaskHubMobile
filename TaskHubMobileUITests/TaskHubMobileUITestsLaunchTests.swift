//
//  TaskHubMobileUITestsLaunchTests.swift
//  TaskHubMobileUITests
//
//  Created by tim on 2/20/26.
//

import XCTest

final class TaskHubMobileUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_MODE"] = "1"
        app.launchEnvironment["UITEST_SCENARIO"] = "ready"
        app.launchEnvironment["UITEST_SKIP_SESSION"] = "1"
        app.launchEnvironment["UITEST_STUB_MUTATIONS"] = "1"
        app.launch()

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Ready Home"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
