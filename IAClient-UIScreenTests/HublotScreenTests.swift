import XCTest

final class HublotScreenTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ flag: String) {
        app = XCUIApplication()
        app.launchArguments = ["-\(flag)", "1"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    @MainActor
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @MainActor
    func testChromeSharesOneLineAndTheModelBarStaysInsideTheScreen() {
        launch("HublotConversationDemo")

        let status = element("status-bar")
        let activity = element("activity-capsule")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("CTX 42%"))
        XCTAssertGreaterThanOrEqual(activity.frame.minX, status.frame.maxX - 1)
        XCTAssertEqual(activity.frame.midY, status.frame.midY, accuracy: 8)

        let options = element("config-options")
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        options.swipeLeft()
        let permissions = element("config-permissions")
        XCTAssertTrue(permissions.waitForExistence(timeout: 5))
        XCTAssertTrue(permissions.isHittable)
        XCTAssertLessThanOrEqual(permissions.frame.maxX, app.frame.maxX - 8)
    }

    @MainActor
    func testToolDetailsExpandWithoutLosingRepeatedCalls() {
        launch("HublotConversationDemo")

        let group = element("tool-group-edit")
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        XCTAssertTrue(group.label.contains("6 appels"))
        group.tap()

        let calls = app.descendants(matching: .button).matching(
            NSPredicate(format: "identifier BEGINSWITH 'tool-call-edit-'")
        )
        XCTAssertEqual(calls.count, 6)
    }

    @MainActor
    func testJumpToLatestActuallyReturnsToTheBottom() {
        launch("HublotConversationDemo")

        let thread = app.scrollViews.firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 5))
        for _ in 0..<5 { thread.swipeDown() }

        let jump = element("jump-to-latest")
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        jump.tap()

        let last = app.staticTexts["FIN DU FIL — réponse la plus récente."]
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        XCTAssertTrue(last.isHittable)
    }

    @MainActor
    func testRadiographyCloseWorksOnTheFirstTap() {
        launch("HublotConversationDemo")

        let open = app.buttons["Ouvrir la radiographie du projet"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()

        let close = element("close-radiography")
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Résumer le dernier prompt"].exists)
    }

    @MainActor
    func testRunningTurnsAreVisibleBeforeOpeningAConversation() {
        launch("HublotProjectsDemo")
        let project = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'office-chess, en cours'")
        ).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 5))

        app.terminate()
        launch("HublotSessionsDemo")
        let session = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Valider les corrections d'interface, en cours")
        ).firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 5))
    }
}
