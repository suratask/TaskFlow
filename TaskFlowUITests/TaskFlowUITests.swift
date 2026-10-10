import XCTest

/// End-to-end checks of the main flows. Run on a simulator: these tests grant Reminders access
/// through the system alert when asked, and clean up the reminders they create.
final class TaskFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // Accept the system permission alerts that appear after the app's own "Continue".
        addUIInterruptionMonitor(withDescription: "System permission alert") { alert in
            for label in ["Allow Full Access", "Allow", "OK", "Allow While Using App"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    /// Launch arguments set UserDefaults for this run only (the argument domain), so no test code ships in the app.
    private func launch(onboardingDone: Bool = true) {
        app.launchArguments = ["-TaskFlow.hasCompletedOnboarding", onboardingDone ? "YES" : "NO"]
        app.launch()
    }

    // MARK: App Review 5.1.1(iv): no "Allow …" buttons before system permission prompts.

    func testOnboardingUsesNeutralPermissionWording() {
        app.resetAuthorizationStatus(for: .reminders)
        app.resetAuthorizationStatus(for: .calendar)
        launch(onboardingDone: false)
        XCTAssertTrue(app.staticTexts["Welcome to TaskFlow Studio"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Continue"].firstMatch.exists)
        assertNoAllowButtons()
    }

    func testSettingsPermissionsUseNeutralWording() {
        launch()
        openSettings()
        app.buttons["Notifications & Permissions"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Notifications & Permissions"].waitForExistence(timeout: 5))
        assertNoAllowButtons()
    }

    // MARK: Settings structure

    func testSettingsShowsFiveGroups() {
        launch()
        openSettings()
        for group in ["General", "Lists", "Calendar", "Notifications & Permissions", "Sync & Data"] {
            XCTAssertTrue(app.buttons[group].firstMatch.waitForExistence(timeout: 5), "Missing Settings group \(group)")
        }
    }

    // MARK: Add, complete, undo

    func testQuickAddShowsRecognizedParts() throws {
        launch()
        let field = try openInlineAddField()
        field.typeText("Buy milk tomorrow #groceries !high")
        // The highlights are one accessibility element labelled "Recognized #groceries, High Priority, …".
        let recognized = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Recognized ")).firstMatch
        XCTAssertTrue(recognized.waitForExistence(timeout: 5))
        XCTAssertTrue(recognized.label.contains("#groceries"), recognized.label)
        XCTAssertTrue(recognized.label.contains("High Priority"), recognized.label)
        field.clearText()
    }

    func testAddCompleteAndUndoTask() throws {
        launch()
        let title = "UI Test \(UUID().uuidString.prefix(6))"
        let field = try openInlineAddField()
        field.typeText(title + "\n")
        let row = app.staticTexts[title].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "New task did not appear")

        // Complete with a leading swipe, then undo from the toast.
        row.swipeRight()
        app.buttons["Complete"].firstMatch.tap()
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Undo toast did not appear")
        undo.tap()
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 10), "Undo did not restore the task")

        // Clean up.
        app.staticTexts[title].firstMatch.swipeLeft()
        if app.buttons["Delete"].firstMatch.waitForExistence(timeout: 3) { app.buttons["Delete"].firstMatch.tap() }
    }

    // MARK: Launch time

    func testLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            launch()
        }
    }

    // MARK: Helpers

    private func openSettings() {
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    /// Opens the Tasks tab, grants Reminders access if needed, and focuses the inline add row.
    private func openInlineAddField() throws -> XCUIElement {
        let tasksTab = app.tabBars.buttons["Tasks"]
        if tasksTab.waitForExistence(timeout: 10) { tasksTab.tap() }
        let continueButton = app.buttons["Continue"].firstMatch
        if continueButton.waitForExistence(timeout: 2) {
            continueButton.tap()
            app.tap() // Lets the interruption monitor handle the system alert.
        }
        // Inbox always has the inline add row once Reminders access is granted.
        let inbox = app.buttons["Inbox"].firstMatch
        if inbox.waitForExistence(timeout: 5) { inbox.tap() }
        let field = app.textFields["inline-new-task-field"]
        guard field.waitForExistence(timeout: 10) else {
            throw XCTSkip("Reminders access is required for this test; grant it in the simulator and run again.")
        }
        field.tap()
        return field
    }

    private func assertNoAllowButtons(file: StaticString = #filePath, line: UInt = #line) {
        let offending = app.buttons.allElementsBoundByIndex
            .map(\.label)
            .filter { $0.hasPrefix("Allow") || $0.hasPrefix("Enable ") || $0.hasPrefix("Connect ") || $0.hasPrefix("Grant") }
        XCTAssertTrue(offending.isEmpty, "Pre-permission buttons must use neutral wording, found: \(offending)", file: file, line: line)
    }
}

private extension XCUIElement {
    func clearText() {
        guard let value = value as? String, !value.isEmpty else { return }
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
    }
}
