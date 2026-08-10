import XCTest

@MainActor
class HublotUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app?.terminate()
        app = nil
        super.tearDown()
    }

    func launch(_ scenario: String, extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-HublotUITestScenario", scenario] + extraArguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    func assertInsideScreen(_ candidate: XCUIElement, inset: CGFloat = 1) {
        XCTAssertTrue(candidate.exists)
        let bounds = app.frame.insetBy(dx: -inset, dy: -inset)
        XCTAssertTrue(bounds.contains(candidate.frame), "\(candidate) deborde: \(candidate.frame) / \(bounds)")
    }
}

final class ConnectionScreenTests: HublotUITestCase {
    func testFieldsEnableConnectionAndExposeTheKeyboard() {
        launch("connection")

        let button = app.buttons["connect-button"]
        let url = app.textFields["connection-url"]
        let token = app.secureTextFields["connection-token"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertFalse(button.isEnabled)

        url.tap()
        url.typeText("ws://127.0.0.1:9")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        token.tap()
        token.typeText("secret")
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: button
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed)
    }

    func testInvalidURLIsRejectedVisiblyAfterTheRealTap() {
        launch("connection")

        let url = app.textFields["connection-url"]
        let token = app.secureTextFields["connection-token"]
        let button = app.buttons["connect-button"]
        url.tap()
        url.typeText("not-a-websocket")
        token.tap()
        token.typeText("secret")
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: button
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed)
        button.tap()

        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Adresse de serveur invalide'")
        ).firstMatch.waitForExistence(timeout: 5))
    }
}

final class ProjectsScreenTests: HublotUITestCase {
    func testProjectAgeShowsTheLastPromptTime() {
        launch("projects-prompt-age")

        let project = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'dernier-prompt'")
        ).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 3))
        XCTAssertTrue(project.label.contains("il y a 1 h"), project.label)
    }

    func testSearchIsCaseInsensitiveAndItsEmptyStateIsObservable() {
        launch("projects")

        let filter = element("project-filter")
        filter.tap()
        filter.typeText("OFFICE")
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'office-chess'")
        ).firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["tg-claude"].exists)

        filter.typeText("-absent")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Aucun depot ne correspond' OR label CONTAINS 'Aucun dépôt ne correspond'")
        ).firstMatch.waitForExistence(timeout: 3))
    }

    func testNewProjectActionDisappearsWhileFiltering() {
        launch("projects")

        let action = element("new-project")
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        let filter = element("project-filter")
        filter.tap()
        filter.typeText("office")

        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(action.waitForNonExistence(timeout: 3))
    }

    func testProjectCanBeCreatedFromTheKeyboard() {
        launch("projects")

        element("new-project").tap()
        let name = app.textFields["nom-du-projet"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.typeText("nouveau-projet")
        let done = app.keyboards.buttons.matching(NSPredicate(
            format: "identifier == 'Done' OR label IN {'Done', 'Termine', 'Terminé', 'terminé'}"
        )).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        done.tap()

        XCTAssertTrue(name.waitForNonExistence(timeout: 10))
    }

    func testStaticEmptyAndErrorStatesStayDistinct() {
        launch("projects-empty")
        XCTAssertTrue(app.staticTexts["Projets"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'indisponible'")
        ).firstMatch.exists)

        app.terminate()
        launch("projects-error")
        XCTAssertTrue(app.staticTexts["Serveur temporairement indisponible."].waitForExistence(timeout: 3))
    }
}

final class SessionsScreenTests: HublotUITestCase {
    private var runningSession: XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Valider les corrections d'interface")
        ).firstMatch
    }

    func testRunningTurnsAreVisibleBeforeOpeningAConversation() {
        launch("sessions")
        XCTAssertTrue(runningSession.waitForExistence(timeout: 5))
        XCTAssertTrue(runningSession.label.contains("en cours"))
    }

    func testFullSwipeDeletesImmediatelyWithoutConfirmation() {
        launch("sessions")
        let row = runningSession
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        // Le geste part du bord droit et traverse toute la largeur. Un simple
        // `swipeLeft()` peut s'arreter au bouton, ce qui ne verifie pas la
        // suppression immediate promise par `allowsFullSwipe`.
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        let finish = app.coordinate(withNormalizedOffset: CGVector(
            dx: 0.02,
            dy: row.frame.midY / app.frame.height
        ))
        start.press(
            forDuration: 0.05, thenDragTo: finish, withVelocity: .fast,
            thenHoldForDuration: 0
        )

        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    func testContextMenuDeletesImmediatelyWithoutConfirmation() {
        launch("sessions")
        let row = runningSession
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1.1)

        let delete = app.buttons["Supprimer"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testInstructionsSheetOpensAndClosesByTouch() {
        launch("sessions-instructions")

        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Valider chaque changement'")
        ).firstMatch.waitForExistence(timeout: 5))
        let close = element("close-instructions")
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))
        XCTAssertTrue(runningSession.exists)
    }

    func testEmptyAndErrorStatesRemainReadable() {
        launch("sessions-empty")
        XCTAssertTrue(app.staticTexts["Aucune conversation"].waitForExistence(timeout: 3))

        app.terminate()
        launch("sessions-error")
        XCTAssertTrue(app.staticTexts["Historique indisponible."].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Aucune conversation"].exists)
    }
}

final class ConversationNavigationScreenTests: HublotUITestCase {
    func testJumpToLatestActuallyReturnsToTheBottom() {
        launch("conversation")

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

    func testConversationAppearsAlreadyAtTheBottomWithoutVisibleCatchUp() {
        launch("conversation")

        let last = app.staticTexts["FIN DU FIL — réponse la plus récente."]
        XCTAssertTrue(last.waitForExistence(timeout: 1))
        XCTAssertTrue(last.isHittable)
        let settledFrame = last.frame

        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        XCTAssertEqual(last.frame.minY, settledFrame.minY, accuracy: 1)
        XCTAssertFalse(element("jump-to-latest").exists)
    }
}

final class ComposerScreenTests: HublotUITestCase {
    func testSendingDismissesKeyboardAndClearsTheDraft() {
        launch("conversation")

        let input = element("composer-input")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Verifie ce correctif")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))

        element("composer-action").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertEqual(input.value as? String, "Message…")
    }
}

final class ConversationBlocksScreenTests: HublotUITestCase {
    func testToolDetailsExpandWithoutLosingRepeatedCalls() {
        launch("conversation")

        let group = element("tool-group-edit")
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        XCTAssertTrue(group.label.contains("6 appels"))
        group.tap()

        let calls = app.descendants(matching: .button).matching(
            NSPredicate(format: "identifier BEGINSWITH 'tool-call-edit-'")
        )
        XCTAssertEqual(calls.count, 6)
    }
}

final class ContextTideScreenTests: HublotUITestCase {
    func testContextTideOpensFromStatusBarAndClosesOnFirstTap() {
        launch("conversation")

        let bar = element("status-bar")
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(bar.label.contains("CTX 42%"))
        bar.tap()

        let close = element("close-context-tide")
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["42"].waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
    }

    func testScrubberReturnsToPastThenBackToLive() {
        launch("context-tide")

        let slider = app.sliders["Chronologie de la maree de contexte"]
        let fallback = app.sliders["Chronologie de la marée de contexte"]
        let scrubber = slider.exists ? slider : fallback
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["MESURE 12 / 12"].waitForExistence(timeout: 5))

        scrubber.adjust(toNormalizedSliderPosition: 0.6)
        XCTAssertTrue(app.staticTexts["MESURE 12 / 12"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["passé"].exists)
        app.buttons["Revenir au direct"].tap()
        XCTAssertTrue(app.staticTexts["MESURE 12 / 12"].waitForExistence(timeout: 5))
    }
}

final class RadiographyScreenTests: HublotUITestCase {
    func testRadiographyCloseWorksOnFirstTap() {
        launch("conversation")

        let open = app.buttons["Ouvrir la radiographie du projet"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()

        let close = element("close-radiography")
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
    }

    func testDenseRegionsStayInsideScreenAndDoNotOverlap() {
        launch("radiography-dense")

        let regions = app.buttons.matching(NSPredicate(format: "label CONTAINS 'actions'"))
        XCTAssertGreaterThanOrEqual(regions.count, 12)
        var frames: [CGRect] = []
        for index in 0..<regions.count {
            let region = regions.element(boundBy: index)
            assertInsideScreen(region, inset: 2)
            let frame = region.frame
            XCTAssertFalse(frames.contains { $0.intersects(frame.insetBy(dx: 2, dy: 2)) })
            frames.append(frame)
        }
    }
}

final class AccessibilityAndLayoutScreenTests: HublotUITestCase {
    func testChromeSharesOneLineAndModelBarStaysInsideScreen() {
        launch("conversation")

        let status = element("status-bar")
        let activity = element("activity-capsule")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(activity.frame.minX, status.frame.maxX - 1)
        XCTAssertEqual(activity.frame.midY, status.frame.midY, accuracy: 8)

        let options = element("config-options")
        options.swipeLeft()
        let permissions = element("config-permissions")
        XCTAssertTrue(permissions.waitForExistence(timeout: 5))
        XCTAssertTrue(permissions.isHittable)
        assertInsideScreen(permissions, inset: 8)
    }

    func testLandscapeChromeAndComposerRemainTouchable() {
        launch("conversation", extraArguments: ["-UIAccessibilityReduceMotionEnabled", "YES"])
        XCUIDevice.shared.orientation = .landscapeLeft

        let status = element("status-bar")
        let input = element("composer-input")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        assertInsideScreen(status, inset: 8)
        assertInsideScreen(input, inset: 8)
        XCTAssertTrue(input.isHittable)
    }

    func testCodexUsesWeeklyWindowAndNeverFiveHourLabel() {
        launch("codex-quota")

        let status = element("status-bar")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("7J: 64%"), "vu : \(status.label)")
        XCTAssertFalse(status.label.contains("5H"), "vu : \(status.label)")
    }

    func testEngineCannotChangeWhileCodexIsStillRunning() {
        launch("active-engine-lock")

        let status = element("status-bar")
        let engine = element("config-engine")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("7J: 36%"), "vu : \(status.label)")
        XCTAssertTrue(engine.waitForExistence(timeout: 5))
        XCTAssertFalse(engine.isEnabled)
        XCTAssertTrue(engine.label.contains("Codex"), "vu : \(engine.label)")
        XCTAssertFalse(engine.label.contains("Claude"), "vu : \(engine.label)")

        // Le geste de la capture ne doit plus ouvrir un choix qui ne pourrait
        // agir qu'au prochain tour, ni faire mentir la barre du tour courant.
        engine.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.buttons["Claude"].waitForExistence(timeout: 1))
        XCTAssertTrue(status.label.contains("7J: 36%"), "vu : \(status.label)")
    }
}
