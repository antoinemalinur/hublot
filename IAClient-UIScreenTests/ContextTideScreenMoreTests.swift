import XCTest

/// La marée de contexte au-delà de son scrubber.
///
/// Ce qu'on vient y chercher est une pente, pas un chiffre : d'où l'on vient, à
/// quelle allure ça monte, et si le sommet est derrière nous. L'inspecteur porte
/// tout cela, et rien ne le vérifiait.
@MainActor
final class ContextTideScreenMoreTests: HublotUITestCase {

    /// La dernière mesure du fil témoin : celle que l'écran affiche au direct.
    private let lastReading = (used: 58_300, size: 200_000)
    /// Douze mesures espacées de 96 secondes depuis un instant fixe.
    private var lastSampleDate: Date {
        Date(timeIntervalSinceReferenceDate: 800_000_000).addingTimeInterval(11 * 96)
    }

    /// T3 — l'inspecteur porte le modèle, le moteur, l'heure et les jetons.
    ///
    /// Rien n'y est estimé : les jetons sont ceux qu'on a reçus, et l'heure est
    /// celle de la mesure, pas celle où on la regarde.
    func testInspectorCarriesModelEngineTimeAndTokens() {
        launch("context-tide")

        let inspector = element("tide-inspector")
        XCTAssertTrue(inspector.waitForExistence(timeout: 10))
        XCTAssertTrue(inspector.staticTexts["Opus 5"].exists, "modèle absent")
        XCTAssertTrue(inspector.staticTexts["claude"].exists, "moteur absent")

        // L'heure est celle de la **mesure**, pas celle où on la regarde. Le
        // format, lui, dépend de la locale que le système donne à l'app — qui
        // n'est pas forcément celle du processus de test. Les deux conventions
        // sont donc admises ; ce qui est vérifié est l'instant.
        let styles = ["fr_FR", "en_US"].map { identifier in
            Date.FormatStyle(date: .omitted, time: .shortened)
                .locale(Locale(identifier: identifier))
        }
        let hours = styles.map { lastSampleDate.formatted($0) }
        XCTAssertTrue(
            hours.contains { inspector.staticTexts[$0].exists },
            "heure de la mesure absente, attendue parmi \(hours)"
        )

        // Les jetons sont mis en forme par l'app. Le test refait la même mise en
        // forme, dans les deux locales possibles, plutôt que d'écrire des
        // séparateurs de milliers à la main.
        let tokens = element("context-token-count")
        XCTAssertTrue(tokens.exists)
        let seen = plainLabel(of: tokens)
        let expected = ["fr_FR", "en_US"].map { identifier -> String in
            let style = IntegerFormatStyle<Int>().locale(Locale(identifier: identifier))
            return "\(lastReading.used.formatted(style)) / \(lastReading.size.formatted(style)) jetons"
        }
        XCTAssertTrue(
            expected.contains(where: { seen.contains(normalised($0)) }),
            "vu « \(seen) », attendu parmi \(expected)"
        )
    }

    /// T6 — un sommet déjà franchi reste un fait de la conversation.
    ///
    /// Une compaction fait retomber le contexte : sans ce rappel, l'écran
    /// laisserait croire qu'on n'a jamais approché du plafond.
    func testPastPeakIsStillAnnounced() {
        launch("context-tide")

        let inspector = element("tide-inspector")
        XCTAssertTrue(inspector.waitForExistence(timeout: 10))
        // 184 900 jetons sur 200 000, avant la compaction.
        XCTAssertTrue(
            inspector.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'sommet atteint'")
            ).firstMatch.exists,
            "aucun sommet annoncé"
        )
        expect(labelled("sommet atteint"), toContain: "92")
        // Et la mesure courante, elle, est bien en dessous.
        XCTAssertTrue(app.staticTexts["29"].exists)
    }

    /// T4 — sans la moindre mesure, la marée le dit.
    func testEmptyTideAnnouncesThatNothingWasMeasured() {
        launch("context-tide-empty")

        XCTAssertTrue(
            app.staticTexts["Aucune mesure de contexte"].waitForExistence(timeout: 10)
        )
        // Ni jauge, ni chronologie, ni inspecteur : il n'y a rien à inspecter.
        assertAbsent(element("tide-inspector"))
        assertAbsent(app.sliders["Chronologie de la marée de contexte"], settle: 0)
        XCTAssertTrue(element("close-context-tide").exists)
    }

    /// T5 — sur un fil terminé, trois mots changent.
    ///
    /// « direct » sur une conversation finie annonçait un mouvement qui n'avait
    /// plus lieu, et le retour en arrière ne peut pas ramener à un présent qui
    /// n'existe plus.
    func testFinishedThreadSaysSoAndOffersToReturnToTheEnd() {
        launch("context-tide-finished")

        XCTAssertTrue(app.staticTexts["terminé"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["direct"].exists)
        // La borne de droite de la chronologie ne dit plus « maintenant ».
        XCTAssertTrue(app.staticTexts["dernière mesure"].exists)

        let scrubber = app.sliders["Chronologie de la marée de contexte"]
        XCTAssertTrue(scrubber.exists)
        scrubber.adjust(toNormalizedSliderPosition: 0.2)

        XCTAssertTrue(app.staticTexts["passé"].waitForExistence(timeout: 5))
        let back = app.buttons["Revenir à la fin"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Revenir au direct"].exists)

        back.tap()
        XCTAssertTrue(app.staticTexts["MESURE 12 / 12"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["terminé"].exists)
    }
}
