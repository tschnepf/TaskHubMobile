import XCTest

final class TaskHubMobileUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBootstrapScenarioShowsConnectScreen() throws {
        let app = launchApp(scenario: "bootstrap")

        XCTAssertTrue(app.textFields["bootstrap.url"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["bootstrap.connect"].exists)
    }

    @MainActor
    func testUnauthenticatedScenarioShowsSignInEntry() throws {
        let app = launchApp(scenario: "unauthenticated")

        XCTAssertTrue(app.staticTexts["auth.required.title"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["auth.signin.button"].exists)
    }

    @MainActor
    func testOnboardingScenarioShowsOnboardingGate() throws {
        let app = launchApp(scenario: "onboarding")

        XCTAssertTrue(app.staticTexts["onboarding.required.title"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["onboarding.retry.button"].exists)
    }

    @MainActor
    func testReadyScenarioSupportsFilterSwitching() throws {
        let app = launchApp(scenario: "ready")

        XCTAssertTrue(app.buttons["filter.work"].waitForExistence(timeout: 2))
        app.buttons["filter.work"].tap()
        XCTAssertTrue(app.staticTexts["Review iOS UX refactor"].waitForExistence(timeout: 2))

        app.buttons["filter.personal"].tap()
        XCTAssertTrue(app.staticTexts["Plan personal errands"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testQuickAddCreatesTaskInReadyScenario() throws {
        let app = launchApp(scenario: "ready")

        XCTAssertTrue(app.buttons["home.quickadd"].waitForExistence(timeout: 2))
        app.buttons["home.quickadd"].tap()

        let titleField = app.textFields["quickadd.title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 2))
        titleField.tap()
        titleField.typeText("UI Test Added Task")

        let submitButton = app.buttons["quickadd.submit"]
        XCTAssertTrue(submitButton.exists)
        submitButton.tap()

        XCTAssertTrue(app.staticTexts["UI Test Added Task"].waitForExistence(timeout: 4))
    }

    @MainActor
    func testOfflineBannerInOfflineScenario() throws {
        let app = launchApp(scenario: "offline")

        let banner = app.otherElements["home.offlineBanner"]
        let bannerText = app.staticTexts["You’re offline. Showing local data."]
        XCTAssertTrue(banner.waitForExistence(timeout: 8) || bannerText.waitForExistence(timeout: 8))
    }

    @MainActor
    func testToggleFailureShowsInlineToast() throws {
        let app = launchApp(scenario: "ready", extraEnvironment: ["UITEST_FORCE_TOGGLE_FAILURE": "1"])

        let quickAdd = app.buttons["home.quickadd"]
        XCTAssertTrue(quickAdd.waitForExistence(timeout: 4))
        quickAdd.tap()

        let titleField = app.textFields["quickadd.title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 4))
        titleField.tap()
        titleField.typeText("Toggle Failure Task")

        let submit = app.buttons["quickadd.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 3))
        submit.tap()

        let newTaskTitle = app.staticTexts["Toggle Failure Task"]
        XCTAssertTrue(newTaskTitle.waitForExistence(timeout: 6))

        let markCompleteButton = app.buttons["Mark complete"].firstMatch
        XCTAssertTrue(markCompleteButton.waitForExistence(timeout: 4))
        markCompleteButton.tap()

        let inlineError = app.descendants(matching: .any)["tasklist.inlineError"]
        let fallbackText = app.staticTexts["Simulated completion failure"]
        XCTAssertTrue(inlineError.waitForExistence(timeout: 8) || fallbackText.waitForExistence(timeout: 8))
    }

    private func launchApp(scenario: String, extraEnvironment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_MODE"] = "1"
        app.launchEnvironment["UITEST_SCENARIO"] = scenario
        app.launchEnvironment["UITEST_SKIP_SESSION"] = "1"
        app.launchEnvironment["UITEST_STUB_MUTATIONS"] = "1"
        for (key, value) in extraEnvironment {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }
}
