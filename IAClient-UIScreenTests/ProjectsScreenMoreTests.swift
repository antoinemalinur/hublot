import XCTest

/// L'écran des dépôts, au-delà du filtre.
///
/// Son sous-titre est calculé à quatre branches — rien, une conversation,
/// plusieurs, et le travail en cours qui prime sur tout le reste — et une seule
/// était vérifiée. C'est pourtant la ligne qu'on lit pour choisir où aller.
@MainActor
final class ProjectsScreenMoreTests: HublotUITestCase {

    /// P8 — un dépôt qui travaille le montre avant qu'on l'ouvre.
    ///
    /// Sans ça, on ne l'apprenait qu'en entrant : une demande longue lancée
    /// avant de ranger le téléphone devenait invisible.
    func testWorkingProjectShowsItsElapsedTime() {
        launch("projects-variants")

        let row = projectRow("depot-actif")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // 134 secondes, écrites comme une horloge.
        expect(row, toContain: "en cours · 2:14")
        XCTAssertFalse(plainLabel(of: row).contains("conversations en cours"), row.label)
    }

    /// P9 — deux tours sur le même dépôt se comptent, et c'est le plus ancien
    /// qui donne l'heure.
    func testProjectWithTwoTurnsCountsThemAndShowsTheLongest() {
        launch("projects-variants")

        let row = projectRow("depot-occupe")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // Deux tours, de 65 s et 200 s : c'est le second qu'on attend.
        expect(row, toContain: "2 conversations en cours · 3:20")
    }

    /// P10 — sans travail en cours, la rangée dit ce qu'il y a à reprendre, au
    /// bon nombre.
    func testIdleProjectsCountTheirConversations() {
        launch("projects-variants")

        let empty = projectRow("depot-vide")
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        expect(empty, toContain: "aucune conversation")
        // Un dépôt vide n'a pas de date à montrer : elle n'apprendrait rien.
        XCTAssertFalse(plainLabel(of: empty).contains("il y a"), empty.label)

        let single = projectRow("depot-unique")
        XCTAssertTrue(single.exists)
        expect(single, toContain: "1 conversation · il y a 1 h")
        XCTAssertFalse(plainLabel(of: single).contains("1 conversations"), single.label)
    }

    /// P14 — un nom trop long ne pousse rien hors de l'écran.
    ///
    /// Le nom se replie ; la rangée, elle, garde ses bords et son chevron —
    /// c'est sur lui qu'on appuie.
    func testOverlongProjectNameKeepsTheRowInsideTheScreen() {
        launch("projects-variants")

        let row = projectRow(
            "infrastructure-de-validation-continue-avec-un-nom-vraiment-tres-long"
        )
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        assertInsideScreen(row, inset: 2)
        XCTAssertTrue(row.isHittable)
        // Le sous-titre survit au nom : c'est lui qui dit quoi reprendre.
        expect(row, toContain: "2 conversations")

        // Et la rangée voisine n'a pas été chassée de l'écran par sa hauteur.
        let neighbour = projectRow("depot-occupe")
        XCTAssertTrue(neighbour.exists)
        assertInsideScreen(neighbour, inset: 2)
    }

    /// P11 — le bouton « Créer » refuse un nom vide.
    func testCreateButtonStaysDisabledUntilANameIsTyped() {
        launch("projects")

        element("new-project").tap()
        let create = element("create-project")
        let name = app.textFields["nom-du-projet"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertFalse(create.isEnabled, "un dépôt sans nom ne doit pas être créable")

        name.typeText("n")
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: create
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed)

        // Effacer le ramène à l'inactif : la règle vaut dans les deux sens.
        name.typeText(XCUIKeyboardKey.delete.rawValue)
        let disabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == false"), object: create
        )
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 3), .completed)
    }

    /// P12 — le bouton « Créer » fait le même travail que la touche du clavier.
    ///
    /// Deux chemins mènent à la création ; un seul était couvert.
    func testProjectCanBeCreatedFromTheButton() {
        launch("projects")

        element("new-project").tap()
        let name = app.textFields["nom-du-projet"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("depot-cree-au-bouton")

        element("create-project").tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 10))
        // L'action principale revient : la rangée de saisie a bien été refermée.
        XCTAssertTrue(element("new-project").waitForExistence(timeout: 5))
    }

    /// P13 — tirer la liste vers le bas la redemande vraiment au serveur.
    ///
    /// Le relais témoin répond deux choses différentes : un rechargement qui ne
    /// rechargerait rien passerait sinon pour un succès.
    func testPullToRefreshAsksTheServerAgain() {
        launch("projects-reload")

        let before = projectRow("avant-rechargement")
        XCTAssertTrue(before.waitForExistence(timeout: 15))

        // Une traction, pas un balayage : le geste descend franchement et
        // **reste tenu** — c'est le doigt maintenu qui arme le rechargement, pas
        // la vitesse. Il part sous l'en-tête flottant, qui recouvre le haut du
        // défilement sans lui appartenir.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
        let finish = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(
            forDuration: 0.2, thenDragTo: finish, withVelocity: .slow,
            thenHoldForDuration: 1.5
        )

        XCTAssertTrue(
            projectRow("apres-rechargement").waitForExistence(timeout: 15),
            "la liste n'a pas été relue"
        )
        XCTAssertTrue(before.waitForNonExistence(timeout: 5))
        // La liste reste une liste : le geste ne l'a pas vidée.
        XCTAssertTrue(element("project-filter").exists)
    }
}
