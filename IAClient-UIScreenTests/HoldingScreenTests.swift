import XCTest

/// L'écran des quelques secondes où il n'y a rien à montrer.
///
/// Il existe parce que son absence a coûté deux fois : un formulaire déjà rempli
/// présenté comme s'il attendait quelque chose, puis un écran blanc sans un seul
/// élément touchable, dont la seule sortie était de tuer l'application.
///
/// Un état transitoire doit se voir *et* se quitter. Ces trois tests vérifient
/// les deux moitiés.
@MainActor
final class HoldingScreenTests: HublotUITestCase {

    /// H1 — au lancement, l'écran prolonge celui du système.
    func testLaunchScreenNamesTheAppAndSaysWhatItIsDoing() {
        launch("holding-launch")

        XCTAssertTrue(app.staticTexts["Hublot"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Connexion au VPS…"].exists)
        // L'issue de secours n'est pas encore là : dix secondes d'attente ne
        // sont pas encore une panne.
        assertAbsent(element("holding-escape"))
    }

    /// H2 — au-delà du raisonnable, l'attente rend la main.
    ///
    /// Le délai réel est de dix secondes ; un test qui les attendrait vraiment
    /// passerait son budget à ne rien faire, d'où la couture qui le raccourcit.
    /// Ce qui est vérifié reste le geste : le bouton apparaît, et son toucher
    /// mène au formulaire.
    func testEscapeAppearsLateAndOpensTheConnectionSettings() {
        launch("holding-launch", extraArguments: ["-HublotHoldingDelay", "1"])

        let escape = element("holding-escape")
        XCTAssertTrue(escape.waitForExistence(timeout: 10))
        expect(escape, toContain: "Modifier la connexion")
        XCTAssertTrue(escape.isHittable)

        escape.tap()

        XCTAssertTrue(app.buttons["connect-button"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["connection-url"].exists)
        XCTAssertTrue(app.staticTexts["Connexion au VPS…"].waitForNonExistence(timeout: 5))
    }

    /// H3 — en cours de route, l'écran ne se présente pas.
    ///
    /// Rappeler à quelqu'un le nom de l'app qu'il a sous les yeux depuis une
    /// heure ne lui apprend rien ; ce qu'il veut savoir est que la liaison se
    /// refait.
    func testReconnectingScreenOmitsTheWordmarkAndReturnsToTheConversations() {
        launch("holding-reconnect", extraArguments: ["-HublotHoldingDelay", "1"])

        XCTAssertTrue(app.staticTexts["Reprise de la liaison…"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Hublot"].exists, "le nom de l'app n'a rien à faire ici")

        let escape = element("holding-escape")
        XCTAssertTrue(escape.waitForExistence(timeout: 10))
        expect(escape, toContain: "Revenir aux conversations")
        escape.tap()

        XCTAssertTrue(element("sessions-back").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Reprise de la liaison…"].waitForNonExistence(timeout: 5))
    }
}
