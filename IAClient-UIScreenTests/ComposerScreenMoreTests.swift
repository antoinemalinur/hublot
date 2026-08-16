import XCTest

/// Le composer : le seul endroit de l'app où l'utilisateur agit vraiment sur la
/// machine.
///
/// Une régression y est immédiatement bloquante, et il y en a déjà eu — un
/// brouillon qui restait affiché après l'envoi, un bouton d'arrêt hors
/// d'atteinte. Ce qui suit couvre ce que les deux tests historiques laissaient
/// de côté : le bouton d'action au repos, la rangée de réglages, le choix d'une
/// valeur, la deuxième mise en file, les pièces jointes et le micro refusé.
@MainActor
final class ComposerScreenMoreTests: HublotUITestCase {

    /// M9 — signalé depuis l'iPhone le 15 août 2026 : une réponse dense
    /// accaparait le MainActor au point que toucher puis écrire paraissait
    /// retardé. Les mille morceaux passent ici par ACPConnection et ChatSession
    /// pendant que le test reproduit le vrai geste au clavier.
    func testComposerStaysResponsiveDuringAThousandChunkBurst() {
        launch("streaming-pressure")

        let input = element("composer-input")
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue(element("streaming-pressure-ready").waitForExistence(timeout: 10))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))

        // L'apparition du clavier déclenche la rafale. La valeur et le bouton
        // vérifient le résultat observable du geste, indépendamment du temps
        // que les trois autres simulateurs font perdre au pilote XCUITest.
        input.typeText("prochaine demande")
        XCTAssertEqual(input.value as? String, "prochaine demande")
        XCTAssertEqual(element("composer-action").label, "Envoyer le message")

        let complete = element("streaming-pressure-complete")
        XCTAssertTrue(complete.waitForExistence(timeout: 15))
        let label = plainLabel(of: complete)
        let digits = label.filter(\.isNumber)
        guard let revisions = Int(digits) else {
            XCTFail("compteur de révisions absent : \(label)")
            return
        }
        XCTAssertLessThanOrEqual(
            revisions, 40,
            "la rafale a invalidé le document \(revisions) fois"
        )
        XCTAssertTrue((input.value as? String ?? "").contains("prochaine demande"))
    }

    /// M3 — au repos le bouton propose la dictée ; dès qu'on écrit, l'envoi.
    ///
    /// C'est la seule chose qui distingue un champ vide d'un champ rempli sur
    /// cet écran : le glyphe change, et avec lui ce que le toucher va faire.
    func testActionButtonSwitchesFromDictationToSending() {
        launch("conversation")

        let action = element("composer-action")
        let input = element("composer-input")
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertEqual(action.label, "Démarrer la dictée")

        input.tap()
        input.typeText("Une demande")

        let sending = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == 'Envoyer le message'"), object: action
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [sending], timeout: 3), .completed, "vu : \(action.label)"
        )
    }

    /// M4 — la rangée de réglages s'efface pendant qu'on écrit, et revient.
    ///
    /// Au moment de formuler une demande, le choix du modèle n'est plus la
    /// question — mais il doit revenir, sinon on ne peut plus le changer sans
    /// quitter l'écran.
    func testSettingsRowHidesWhileWritingAndComesBack() {
        launch("conversation")

        let options = element("config-options")
        let input = element("composer-input")
        XCTAssertTrue(options.waitForExistence(timeout: 5))

        input.tap()
        input.typeText("Je réfléchis à voix haute")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(options.waitForNonExistence(timeout: 3))

        // Envoyer termine la saisie : le focus tombe, et la rangée doit
        // reparaître d'elle-même.
        element("composer-action").tap()
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        XCTAssertTrue(element("config-model").exists)
    }

    /// M5 — choisir une valeur change ce que la pilule affiche.
    ///
    /// La pilule *est* la valeur courante : il n'y a pas d'étiquette à côté. Si
    /// elle ne suit pas le choix, l'écran ment sur ce qui partira au prochain
    /// tour.
    func testChoosingAValueRenamesThePill() {
        launch("engine-switch-quota")

        let engine = element("config-engine")
        XCTAssertTrue(engine.waitForExistence(timeout: 10))
        expect(engine, toContain: "Codex", timeout: 10)

        engine.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let claude = app.buttons["Claude"]
        XCTAssertTrue(claude.waitForExistence(timeout: 5))
        claude.tap()

        expect(engine, toContain: "Claude", timeout: 10)
        XCTAssertFalse(plainLabel(of: engine).contains("Codex"), "vu : \(engine.label)")
    }

    /// M6 — deux messages confiés pendant un tour se comptent au pluriel.
    ///
    /// Le singulier était couvert ; le pluriel est une autre branche du même
    /// libellé, et c'est celle qu'on lit quand on a vraiment empilé du travail.
    func testTwoQueuedMessagesAreCountedInThePlural() {
        launch("conversation-working")

        let input = element("composer-input")
        let action = element("composer-action")
        XCTAssertTrue(input.waitForExistence(timeout: 5))

        input.tap()
        input.typeText("Premier message en attente")
        action.tap()

        let queue = element("composer-queue")
        XCTAssertTrue(queue.waitForExistence(timeout: 5))
        expect(queue, toContain: "1 message en attente")

        input.tap()
        input.typeText("Second message en attente")
        action.tap()

        expect(queue, toContain: "2 messages en attente", timeout: 5)
        // Et un seul élément porte ce compteur : le `Label` en expose deux si
        // on oublie de les fondre, et VoiceOver énonce alors la file deux fois.
        XCTAssertEqual(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == 'composer-queue'")
            ).count, 1
        )
    }

    /// M7 — une pièce jointe annonce son poids, et sa croix la retire.
    ///
    /// Le poids est là parce qu'il se paie : une capture part depuis un réseau
    /// mobile, et le savoir avant vaut mieux que le découvrir après.
    func testAttachmentShowsItsWeightAndCanBeRemoved() {
        launch("composer-attachment")

        let chip = element("attachment-chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        let weight = plainLabel(of: chip)
        XCTAssertTrue(
            weight.range(of: "[1-9][0-9]* (ko|o)", options: .regularExpression) != nil,
            "poids illisible : \(weight)"
        )

        // Une image seule suffit à envoyer : le bouton doit déjà proposer
        // l'envoi, pas la dictée.
        XCTAssertEqual(element("composer-action").label, "Envoyer le message")

        element("attachment-remove").tap()
        XCTAssertTrue(chip.waitForNonExistence(timeout: 5))
        // Et le bouton redevient ce qu'il était : il n'y a plus rien à envoyer.
        let dictating = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == 'Démarrer la dictée'"),
            object: element("composer-action")
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dictating], timeout: 3), .completed)
    }

    /// M8 — micro refusé : l'invite dit où le rétablir.
    ///
    /// Rien dans l'app ne peut deviner une autorisation refusée dans les
    /// Réglages du système ; l'invite est donc la seule issue offerte.
    func testRefusedMicrophoneSendsBackToTheSettings() {
        launch("composer-refused-mic")

        let input = element("composer-input")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let placeholder = (input.value as? String ?? "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        XCTAssertTrue(placeholder.contains("Micro refusé"), "vu : \(placeholder)")
        XCTAssertTrue(placeholder.contains("Réglages"), "vu : \(placeholder)")

        // Le champ reste utilisable au clavier : un micro refusé n'interdit pas
        // d'écrire.
        input.tap()
        input.typeText("Je tape à la place")
        XCTAssertEqual(element("composer-action").label, "Envoyer le message")
    }
}
