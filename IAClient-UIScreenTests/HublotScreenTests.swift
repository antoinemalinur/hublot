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
    func testConversationAppearsAlreadyAtTheBottomWithoutVisibleCatchUp() {
        launch("HublotConversationDemo")

        let last = app.staticTexts["FIN DU FIL — réponse la plus récente."]
        XCTAssertTrue(last.waitForExistence(timeout: 1))
        XCTAssertTrue(last.isHittable)
        let settledFrame = last.frame

        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        XCTAssertEqual(last.frame.minY, settledFrame.minY, accuracy: 1)
        XCTAssertFalse(element("jump-to-latest").exists)
    }

    @MainActor
    func testSendingDismissesTheKeyboard() {
        launch("HublotConversationDemo")

        let input = element("composer-input")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Vérifie ce correctif")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))

        element("composer-action").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testNewProjectActionDisappearsWhileFiltering() {
        launch("HublotProjectsDemo")

        let action = element("new-project")
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        let filter = element("project-filter")
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap()
        filter.typeText("office")

        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(action.waitForNonExistence(timeout: 3))
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
    func testContextTideOpensFromTheStatusBarAndClosesOnTheFirstTap() {
        launch("HublotConversationDemo")

        let bar = element("status-bar")
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        // La barre reste lisible : ouvrir la marée ne doit pas coûter les
        // chiffres qu'on venait consulter.
        XCTAssertTrue(bar.label.contains("CTX 42%"))
        bar.tap()

        let close = element("close-context-tide")
        XCTAssertTrue(close.waitForExistence(timeout: 5))

        // La marée montre bien la mesure de la barre, pas un écran vide.
        XCTAssertTrue(app.staticTexts["42"].waitForExistence(timeout: 5))

        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Résumer le dernier prompt"].exists)
    }

    @MainActor
    func testContextTideScrubberReturnsToThePast() {
        launch("HublotContextTideDemo")

        let slider = app.sliders["Chronologie de la marée de contexte"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))

        // Le fil témoin finit après une compaction, donc bas. Remonter la
        // chronologie doit faire réapparaître le sommet — c'est tout l'intérêt
        // du curseur, et ça ne marche que si la carte se fige vraiment.
        let live = app.staticTexts["MESURE 12 / 12"]
        XCTAssertTrue(live.waitForExistence(timeout: 5))

        slider.adjust(toNormalizedSliderPosition: 0.6)

        let frozen = app.staticTexts["MESURE 12 / 12"]
        XCTAssertTrue(frozen.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["passé"].exists)

        let back = app.buttons["Revenir au direct"]
        XCTAssertTrue(back.exists)
        back.tap()
        XCTAssertTrue(app.staticTexts["MESURE 12 / 12"].waitForExistence(timeout: 5))
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
