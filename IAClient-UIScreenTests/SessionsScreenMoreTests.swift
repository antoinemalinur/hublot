import XCTest

/// Les conversations d'un dépôt, au-delà de la suppression.
///
/// Trois choses s'y lisent avant d'ouvrir : laquelle reprendre, combien
/// d'échanges elle porte, et si le dépôt a un règlement à connaître. Les trois
/// sont des libellés calculés, et aucun n'était vérifié.
@MainActor
final class SessionsScreenMoreTests: HublotUITestCase {

    /// S9 — un balayage partiel révèle « Supprimer » au lieu de supprimer.
    ///
    /// Le balayage complet est couvert parce qu'il supprime sans confirmation.
    /// Le partiel est l'autre moitié du même geste : il doit s'arrêter sur le
    /// bouton, et ne supprimer qu'au toucher.
    func testPartialSwipeRevealsTheDeleteButtonBeforeDeleting() {
        launch("sessions")

        let row = sessionRow("screen-running")
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        // Un tiers de la largeur : assez pour ouvrir le tiroir, pas assez pour
        // déclencher la suppression immédiate.
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let finish = row.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        start.press(
            forDuration: 0.1, thenDragTo: finish, withVelocity: .slow,
            thenHoldForDuration: 0.3
        )

        let delete = app.buttons["Supprimer"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertTrue(row.exists, "le balayage partiel ne doit pas supprimer")

        delete.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    /// S10 — la plus récente est marquée : c'est celle qu'on reprend neuf fois
    /// sur dix.
    func testLatestConversationIsMarked() {
        launch("sessions-variants")

        let latest = sessionRow("variante-recente")
        XCTAssertTrue(latest.waitForExistence(timeout: 10))
        expect(latest, toContain: "dernière")

        // Et elle seule : la marque n'aurait aucun sens sur trois rangées.
        for identifier in ["variante-unique", "variante-ancienne"] {
            let row = sessionRow(identifier)
            XCTAssertTrue(row.exists)
            XCTAssertFalse(plainLabel(of: row).contains("dernière"), row.label)
        }
    }

    /// S11 — un seul échange se dit au singulier.
    func testSingleExchangeIsWrittenInTheSingular() {
        launch("sessions-variants")

        let single = sessionRow("variante-unique")
        XCTAssertTrue(single.waitForExistence(timeout: 10))
        expect(single, toContain: "1 échange")
        XCTAssertFalse(plainLabel(of: single).contains("1 échanges"), single.label)

        let many = sessionRow("variante-ancienne")
        XCTAssertTrue(many.exists)
        expect(many, toContain: "12 échanges")
    }

    /// S12 — sans fichier d'instructions, pas de bouton.
    ///
    /// Le bouton n'existe que s'il y a quelque chose à lire ; son absence ne se
    /// vérifie que sur un dépôt qui n'en a réellement pas.
    func testInstructionsButtonIsAbsentWithoutADocument() {
        launch("sessions-variants")

        XCTAssertTrue(sessionRow("variante-recente").waitForExistence(timeout: 10))
        assertAbsent(element("instructions-button"))
        // L'en-tête est bien là : c'est le bouton qui manque, pas l'écran.
        XCTAssertTrue(element("sessions-back").exists)
    }

    /// S13 — la feuille d'instructions défile sous son en-tête.
    ///
    /// Le chemin du document reste en tête : c'est ce qui dit *quel* règlement
    /// on lit, et le perdre au premier défilement rendrait la feuille anonyme.
    func testInstructionsSheetScrollsUnderItsHeader() {
        launch("sessions-instructions-long")

        let path = app.staticTexts["/root/repos/office-chess/CLAUDE.md"]
        XCTAssertTrue(path.waitForExistence(timeout: 15))
        let header = path.frame

        let sheet = app.scrollViews.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        for _ in 0..<4 { sheet.swipeUp() }

        // Le document a bougé…
        XCTAssertTrue(
            app.staticTexts["Règle 30"].waitForExistence(timeout: 5),
            "la feuille n'a pas défilé"
        )
        // …l'en-tête, non.
        XCTAssertTrue(path.exists, "le chemin du document a disparu")
        XCTAssertEqual(path.frame.minY, header.minY, accuracy: 1)

        element("close-instructions").tap()
        XCTAssertTrue(path.waitForNonExistence(timeout: 5))
    }

    /// S14 — tirer la liste des conversations la redemande vraiment au serveur.
    ///
    /// Le relais témoin répond deux choses différentes, exactement comme pour
    /// les dépôts. Sans ça, une liste rechargée et une liste jamais relue ont la
    /// même apparence, et le test se contenterait de constater que rien n'a
    /// disparu — ce qu'un rechargement inerte réussit parfaitement.
    func testPullToRefreshAsksTheServerForTheConversationsAgain() {
        launch("sessions-reload")

        let before = sessionRow("fil-avant-rechargement")
        XCTAssertTrue(before.waitForExistence(timeout: 15))

        // Même geste que sur les dépôts : les coordonnées de la fenêtre, un
        // tirage lent, et le doigt tenu — c'est lui qui arme le rechargement.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
        let finish = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(
            forDuration: 0.2, thenDragTo: finish, withVelocity: .slow,
            thenHoldForDuration: 1.5
        )

        XCTAssertTrue(
            sessionRow("fil-apres-rechargement").waitForExistence(timeout: 15),
            "la liste n'a pas été relue"
        )
        XCTAssertTrue(before.waitForNonExistence(timeout: 5))
        // Et la liste reste une liste : le geste ne l'a pas vidée en chemin.
        XCTAssertTrue(element("sessions-back").exists)
        assertAbsent(app.staticTexts["Aucune conversation"], settle: 0.5)
    }
}
