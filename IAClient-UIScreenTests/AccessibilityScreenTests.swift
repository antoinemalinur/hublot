import XCTest

/// L'app sur un appareil réglé autrement que celui du développeur.
///
/// Ces défauts ne cassent rien fonctionnellement : ils rendent l'app inutilisable
/// pour qui a tourné son téléphone, agrandi ses caractères ou coupé les
/// animations. Le fil était couvert en paysage ; les listes ne l'étaient pas, et
/// aucune taille de texte ne l'était nulle part.
@MainActor
final class AccessibilityScreenTests: HublotUITestCase {

    /// A2 — les dépôts en paysage.
    func testProjectsStayReachableInLandscape() {
        launch("projects", extraArguments: ["-UIAccessibilityReduceMotionEnabled", "YES"])
        XCUIDevice.shared.orientation = .landscapeLeft

        let filter = element("project-filter")
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        assertInsideScreen(filter, inset: 8)
        XCTAssertTrue(filter.isHittable)

        let disconnect = element("disconnect")
        XCTAssertTrue(disconnect.exists)
        assertInsideScreen(disconnect, inset: 8)
        XCTAssertTrue(disconnect.isHittable)

        let row = projectRow("office-chess")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        assertInsideScreen(row, inset: 8)
        XCTAssertTrue(row.isHittable)
    }

    /// A2 — les conversations en paysage.
    func testConversationsStayReachableInLandscape() {
        launch("sessions", extraArguments: ["-UIAccessibilityReduceMotionEnabled", "YES"])
        XCUIDevice.shared.orientation = .landscapeLeft

        let back = element("sessions-back")
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        assertInsideScreen(back, inset: 8)
        XCTAssertTrue(back.isHittable)

        let action = app.buttons["Nouvelle conversation"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        assertInsideScreen(action, inset: 8)
        XCTAssertTrue(action.isHittable)

        let row = sessionRow("screen-running")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        assertInsideScreen(row, inset: 8)
    }

    /// A3 — une taille de caractères accessible sur les dépôts.
    ///
    /// Les rangées grandissent ; ce qui ne doit pas grandir, c'est ce qui sort
    /// de l'écran.
    func testProjectsRemainUsableAtAccessibleTextSize() {
        launchWithLargeText("projects")

        // Un dépôt au repos : son sous-titre est le plus long des quatre, et
        // c'est donc lui qui déborde le premier.
        let row = projectRow("tg-claude")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        assertInsideScreen(row, inset: 2)
        XCTAssertTrue(row.isHittable)
        // Le sous-titre reste lisible en entier : c'est lui qui dit quoi
        // reprendre.
        expect(row, toContain: "2 conversations")

        let action = element("new-project")
        XCTAssertTrue(action.exists)
        assertInsideScreen(action, inset: 8)
        XCTAssertTrue(action.isHittable)
    }

    /// A3 — une taille de caractères accessible sur les conversations.
    func testConversationsRemainUsableAtAccessibleTextSize() {
        launchWithLargeText("sessions")

        let row = sessionRow("screen-running")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        assertInsideScreen(row, inset: 2)
        XCTAssertTrue(row.isHittable)

        let action = app.buttons["Nouvelle conversation"]
        XCTAssertTrue(action.exists)
        assertInsideScreen(action, inset: 8)
        XCTAssertTrue(action.isHittable)
        // Le retour de l'en-tête ne se fait pas chasser par le titre du dépôt.
        let back = element("sessions-back")
        XCTAssertTrue(back.exists)
        assertInsideScreen(back, inset: 8)
        XCTAssertTrue(back.isHittable)
    }

    /// A4 — la marée, animations coupées, ne peint plus.
    ///
    /// Le tracé est dessiné dans un `Canvas` battu par une `TimelineView` à
    /// trente images par seconde, et une pulsation voyage sur la dernière
    /// mesure. Chez qui a demandé que rien ne bouge, elle ne doit pas battre —
    /// et une position d'élément ne le dit pas : le dessin vit dans un canevas
    /// que l'arbre d'accessibilité ne décrit pas. Deux captures espacées d'une
    /// seconde, elles, le disent.
    func testContextTideStopsPaintingWithReducedMotion() {
        launch("context-tide", extraArguments: ["-UIAccessibilityReduceMotionEnabled", "YES"])

        let reading = app.staticTexts["29"]
        XCTAssertTrue(reading.waitForExistence(timeout: 10))
        XCTAssertTrue(element("tide-inspector").exists)
        // Le temps que l'apparition de l'écran se termine.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        let first = app.screenshot().image
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        let second = app.screenshot().image

        let difference = VisualSnapshotScreenTests.difference(first, second)
        XCTAssertLessThanOrEqual(
            difference.changedRatio, 0.001,
            "\(difference.changedRatio * 100) % des pixels bougent encore"
        )
    }

    /// A4 — la radiographie, animations coupées, garde ses régions en place et
    /// atteignables.
    func testRadiographyStaysSteadyAndTouchableWithReducedMotion() {
        launch("radiography", extraArguments: ["-UIAccessibilityReduceMotionEnabled", "YES"])

        let region = element("region-Domain")
        XCTAssertTrue(region.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let placed = region.frame

        let first = app.screenshot().image
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        let second = app.screenshot().image

        XCTAssertEqual(region.frame.minX, placed.minX, accuracy: 1)
        XCTAssertEqual(region.frame.minY, placed.minY, accuracy: 1)
        XCTAssertTrue(region.isHittable)

        let difference = VisualSnapshotScreenTests.difference(first, second)
        XCTAssertLessThanOrEqual(
            difference.changedRatio, 0.001,
            "\(difference.changedRatio * 100) % des pixels bougent encore"
        )
    }
}
