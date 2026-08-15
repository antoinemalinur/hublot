import XCTest

/// La radiographie au-delà de sa géométrie.
///
/// Le placement des disques était couvert — c'est lui qui avait cassé. Ce qu'on
/// fait de la carte ne l'était pas : nommer une région au toucher, lire combien
/// il y en a, revenir en arrière dans les actions, et distinguer une région en
/// échec des autres.
@MainActor
final class RadiographyScreenMoreTests: HublotUITestCase {

    /// R3 — toucher une région ouvre son inspecteur ; le retoucher le ferme.
    ///
    /// Une carte trop peuplée renonce à écrire les noms : c'est ce geste, et lui
    /// seul, qui permet alors de savoir ce qu'on regarde.
    func testTouchingARegionOpensAndClosesItsInspector() {
        launch("radiography")

        let region = element("region-Domain")
        XCTAssertTrue(region.waitForExistence(timeout: 10))
        // Sans sélection, c'est la légende qui occupe la place.
        XCTAssertTrue(element("radiography-legend").exists)

        region.tap()

        let inspector = element("region-inspector")
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        expect(inspector, toContain: "Domain")
        expect(inspector, toContain: "1 action")
        // Le fichier réellement touché, pas seulement son dossier.
        expect(inspector, toContain: "ChatSession.swift")
        XCTAssertFalse(element("radiography-legend").exists)

        region.tap()
        XCTAssertTrue(inspector.waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("radiography-legend").waitForExistence(timeout: 5))
    }

    /// R4 — la légende compte les régions.
    func testLegendCountsTheRegions() {
        launch("radiography")

        let legend = element("radiography-legend")
        XCTAssertTrue(legend.waitForExistence(timeout: 10))
        // Quatre appels dans quatre endroits distincts : deux dossiers du dépôt,
        // le terminal, et le serveur.
        expect(legend, toContain: "4 régions")
        expect(legend, toContain: "observé")
        expect(legend, toContain: "échec")
    }

    /// R7 — une région en échec le dit dans son libellé.
    ///
    /// La couleur seule ne suffit pas : un lecteur d'écran doit l'entendre, et
    /// un test ne peut pas lire une teinte.
    func testFailedRegionSaysSoInItsLabel() {
        launch("radiography")

        let failed = element("region-Server")
        XCTAssertTrue(failed.waitForExistence(timeout: 10))
        expect(failed, toContain: "en échec")

        // Et la région voisine, elle, ne le dit pas : l'échec n'est pas
        // contagieux.
        let other = element("region-Domain")
        XCTAssertTrue(other.exists)
        XCTAssertFalse(plainLabel(of: other).contains("en échec"), other.label)
    }

    /// R5 — la chronologie ramène la carte à une action passée, puis au direct.
    func testTimelineFreezesThenReturnsToLive() {
        launch("radiography")

        let scrubber = app.sliders["Chronologie de la radiographie"]
        XCTAssertTrue(scrubber.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["ACTION 4 / 4"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["direct"].exists)

        scrubber.adjust(toNormalizedSliderPosition: 0)
        XCTAssertTrue(app.staticTexts["ACTION 1 / 4"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["passé"].exists)
        // Ramenée à sa première action, la carte n'a plus qu'une région.
        XCTAssertTrue(element("region-Domain").exists)
        assertAbsent(element("region-Server"), settle: 0.5)

        app.buttons["Revenir au direct"].tap()
        XCTAssertTrue(app.staticTexts["ACTION 4 / 4"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("region-Server").waitForExistence(timeout: 5))
    }

    /// R6 — un fil sans le moindre outil n'a rien à cartographier, et le dit.
    func testEmptyRadiographyAnnouncesThatNothingWasObserved() {
        launch("radiography-empty")

        XCTAssertTrue(
            app.staticTexts["Aucune région observée"].waitForExistence(timeout: 10)
        )
        // Ni légende, ni chronologie : il n'y a rien à légender ni à parcourir.
        assertAbsent(element("radiography-legend"))
        assertAbsent(app.sliders["Chronologie de la radiographie"], settle: 0)
        // Mais la sortie reste offerte.
        XCTAssertTrue(element("close-radiography").exists)
    }
}
