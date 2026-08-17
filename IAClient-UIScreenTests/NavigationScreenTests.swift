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

    /// F21 — signalé depuis l'iPhone le 16 août 2026 : ouvrir une discussion
    /// a toujours laissé la liste immobile pendant environ une seconde. Le
    /// relais retient ici le rejeu trois secondes pour rendre cette latence
    /// historique déterministe, puis fournit un vrai contenu ACP.
    func testDiscussionShellAppearsBeforeItsHistoryReturns() {
        launch("discussion-loading")

        let project = projectRow("hublot")
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()

        let session = sessionRow("fil-a-reprendre")
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.tap()

        // Le nouvel écran répond au doigt; il ne dépend pas de la réponse
        // réseau qui est encore explicitement retenue par le relais.
        let back = element("conversation-back")
        XCTAssertTrue(back.waitForExistence(timeout: 1))
        expect(back, toContain: "Reprendre le fil", timeout: 1)
        XCTAssertTrue(element("conversation-loading").exists)

        // Le chargement ne fabrique pas le résultat : le texte attendu traverse
        // ensuite le vrai décodage, ACPConnection et ChatSession.
        XCTAssertTrue(labelled("Réponse retrouvée").waitForExistence(timeout: 6))
        XCTAssertTrue(element("conversation-loading").waitForNonExistence(timeout: 1))
        XCTAssertTrue(element("composer-input").exists)
    }

    /// P8 — signalé depuis l'iPhone le 15 août 2026 : entrer dans un dépôt
    /// additionnait deux attentes réseau et la destination restait vide. Le
    /// relais retient liste et instructions trois secondes; l'écran doit donc
    /// répondre avant elles et dire honnêtement ce qu'il attend.
    func testProjectEntryIsImmediateWhileItsResourcesLoad() {
        launch("project-loading")

        let project = projectRow("hublot")
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()

        let back = element("sessions-back")
        let loading = element("sessions-loading")
        // La destination et son état transitoire doivent appartenir ensemble
        // à l'arbre accessible, avant que la vraie rangée réseau les remplace.
        XCTAssertTrue(back.exists)
        XCTAssertTrue(loading.exists)
        expect(back, toContain: "hublot", timeout: 1)

        let action = element("new-session")
        XCTAssertTrue(action.waitForExistence(timeout: 1))
        XCTAssertTrue(action.isEnabled)
        XCTAssertTrue(action.isHittable)

        // Les deux réponses finissent ensemble; le chargement cède alors la
        // place à la vraie rangée, jamais à un faux état vide intermédiaire.
        XCTAssertTrue(sessionRow("charge").waitForExistence(timeout: 6))
        XCTAssertTrue(loading.waitForNonExistence(timeout: 1))
    }

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
