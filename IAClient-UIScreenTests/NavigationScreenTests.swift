import XCTest

/// Le chemin d'entrée de l'app, dans les deux sens.
///
/// Aucune de ces navigations n'était vérifiée. C'est pourtant celui que toute
/// session emprunte : dépôts → conversations → fil, et les retours. Une
/// régression ici rend l'app inutilisable, et aucune autre vérification ne se
/// joue derrière.
///
/// Le relais témoin ne dort jamais et ne rend qu'un dépôt et qu'une
/// conversation : ce qui est vérifié est le passage d'un écran à l'autre, pas ce
/// que le serveur raconte.
@MainActor
final class NavigationScreenTests: HublotUITestCase {

    /// P6 — toucher un dépôt ouvre ses conversations, sous son nom.
    func testTouchingAProjectOpensItsConversationsUnderItsName() {
        launch("navigation")

        let project = projectRow("hublot")
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()

        // L'en-tête de l'écran suivant porte le nom du dépôt qu'on vient de
        // toucher : c'est ce qui distingue « on a changé d'écran » de « on a
        // ouvert le mauvais dépôt ».
        let back = element("sessions-back")
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        expect(back, toContain: "hublot")

        let session = sessionRow("fil-a-reprendre")
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        expect(session, toContain: "Reprendre le fil")
    }

    /// S8 — le retour de l'en-tête des conversations ramène aux dépôts.
    func testHeaderBackReturnsFromConversationsToProjects() {
        launch("navigation")

        let project = projectRow("hublot")
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()

        let back = element("sessions-back")
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()

        XCTAssertTrue(projectRow("hublot").waitForExistence(timeout: 10))
        // Et l'écran des dépôts, pas seulement sa rangée : le filtre et la
        // déconnexion n'appartiennent qu'à lui.
        XCTAssertTrue(element("project-filter").exists)
        XCTAssertTrue(element("disconnect").exists)
    }

    /// F15 — ouvrir un fil et en ressortir, sans perdre la conversation.
    func testConversationOpensAndItsBackReturnsToTheList() {
        launch("navigation")

        let project = projectRow("hublot")
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()

        let session = sessionRow("fil-a-reprendre")
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.tap()

        // Le fil est là : son retour et son composer n'existent que sur lui.
        let conversationBack = element("conversation-back")
        XCTAssertTrue(conversationBack.waitForExistence(timeout: 15))
        XCTAssertTrue(element("composer-input").waitForExistence(timeout: 10))
        expect(conversationBack, toContain: "Reprendre le fil")

        conversationBack.tap()

        // On revient aux conversations du dépôt — pas aux dépôts : enchaîner
        // deux fils sur le même dépôt est le cas courant.
        XCTAssertTrue(sessionRow("fil-a-reprendre").waitForExistence(timeout: 10))
        XCTAssertTrue(element("sessions-back").exists)
    }

    /// P7 — « Déconnecter » est le seul chemin qui remontre le formulaire.
    func testDisconnectBringsBackTheConnectionForm() {
        launch("navigation")

        let disconnect = element("disconnect")
        XCTAssertTrue(disconnect.waitForExistence(timeout: 10))
        disconnect.tap()

        XCTAssertTrue(app.buttons["connect-button"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["connection-url"].exists)
        // La liste ne doit pas rester derrière : c'est une déconnexion, pas une
        // feuille par-dessus.
        XCTAssertTrue(projectRow("hublot").waitForNonExistence(timeout: 5))
    }
}
