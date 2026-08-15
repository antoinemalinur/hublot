import XCTest

/// Chaque type de bloc du fil, et son pli.
///
/// C'est ce qu'on vient lire. Les régressions y sont visuelles et silencieuses :
/// un pli qui ne s'ouvre plus ne casse rien, il cache — et un échec qui cesse de
/// s'ouvrir tout seul laisse croire à une commande passée sans histoire.
///
/// Le fil témoin porte un exemplaire de chaque bloc et s'ouvre en bas, comme
/// tous les fils : ce qui est en tête se rejoint en défilant.
@MainActor
final class ThreadBlocksScreenTests: HublotUITestCase {

    private var thread: XCUIElement { app.scrollViews.firstMatch }

    /// Remonte jusqu'à ce que l'élément soit là, ou renonce.
    ///
    /// « Là » veut dire entièrement dans l'écran : un bloc à moitié engagé sous
    /// le chrome existe déjà pour XCUITest, alors qu'on ne peut ni le lire ni le
    /// toucher.
    @discardableResult
    private func scrollUpTo(_ element: XCUIElement, attempts: Int = 12) -> Bool {
        for _ in 0..<attempts {
            if element.exists, element.frame.minY >= app.frame.minY { return true }
            thread.swipeDown()
        }
        return element.exists && element.frame.minY >= app.frame.minY
    }

    /// B2 — un appel isolé s'ouvre au toucher, et se referme au suivant.
    func testLoneToolCallOpensAndClosesOnTouch() {
        launch("thread-blocks")

        let call = element("tool-call-diff")
        XCTAssertTrue(call.waitForExistence(timeout: 10))

        // Replié, le détail du diff n'est pas là.
        let path = app.staticTexts["IAClient-UI/Domain/ChatSession.swift"]
        XCTAssertFalse(path.exists)

        call.tap()
        XCTAssertTrue(path.waitForExistence(timeout: 5))

        call.tap()
        XCTAssertTrue(path.waitForNonExistence(timeout: 5))
    }

    /// B3 — un appel en échec est déjà ouvert : c'est la seule fois où l'on veut
    /// le détail sans l'avoir demandé.
    func testFailedToolCallIsAlreadyExpanded() {
        launch("thread-blocks")

        let output = app.staticTexts["SORTIE DU TERMINAL — 1 failed, 12 passed."]
        XCTAssertTrue(
            output.waitForExistence(timeout: 10),
            "l'échec devrait s'ouvrir sans qu'on le touche"
        )
        // Et personne n'a touché la ligne : elle est toujours dépliable dans
        // l'autre sens.
        element("tool-call-echec").tap()
        XCTAssertTrue(output.waitForNonExistence(timeout: 5))
    }

    /// B4 — le raisonnement s'ouvre sous son libellé.
    func testReasoningBlockRevealsItsTextUnderItsCaption() {
        launch("thread-blocks")

        let caption = labelled("raisonnement")
        XCTAssertTrue(scrollUpTo(caption), "libellé de raisonnement introuvable")
        expect(caption, toContain: "raisonnement")

        let body = app.staticTexts["RAISONNEMENT VISIBLE — le tampon n'était pas vidé."]
        XCTAssertFalse(body.exists, "le raisonnement doit être replié par défaut")
        caption.tap()
        XCTAssertTrue(body.waitForExistence(timeout: 5))
    }

    /// B5 — répondre à une permission remplace les boutons par le verdict, dans
    /// les mots mêmes du bouton pressé.
    func testAnsweringAPermissionReplacesTheButtonsWithTheVerdict() {
        launch("thread-blocks")

        let allow = app.buttons["Autoriser une fois"]
        let refuse = app.buttons["Refuser"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10))
        XCTAssertTrue(refuse.exists)

        allow.tap()

        // La question ne se repose pas : les deux boutons partent ensemble.
        XCTAssertTrue(refuse.waitForNonExistence(timeout: 5))
        XCTAssertFalse(allow.exists)
        // Et le verdict porte le libellé de l'agent, pas un mot de l'app.
        XCTAssertTrue(labelled("Autoriser une fois").waitForExistence(timeout: 5))
    }

    /// B6 — une permission déjà tranchée s'affiche en verdict, sans boutons.
    func testSettledPermissionShowsItsVerdictWithoutButtons() {
        launch("thread-blocks")

        let verdict = labelled("Toujours autoriser")
        XCTAssertTrue(verdict.waitForExistence(timeout: 10))
        // Le verdict n'est pas un bouton : on ne repose pas une question déjà
        // tranchée.
        XCTAssertFalse(app.buttons["Toujours autoriser"].exists)
        XCTAssertTrue(app.staticTexts["git push origin main"].exists)
    }

    /// B7 — un diff porte ses marqueurs.
    func testDiffCarriesItsAddedAndRemovedMarkers() {
        launch("thread-blocks")

        let call = element("tool-call-diff")
        XCTAssertTrue(call.waitForExistence(timeout: 10))
        call.tap()

        XCTAssertTrue(app.staticTexts["let nouvelle = 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["let ancienne = 1"].exists)
        XCTAssertTrue(app.staticTexts["+"].exists, "marqueur d'ajout absent")
        // Le retrait s'écrit avec un vrai signe moins, pas un trait d'union :
        // c'est la typographie du diff, et un test au clavier ne la retrouve
        // qu'en l'écrivant tel quel.
        XCTAssertTrue(app.staticTexts["\u{2212}"].exists, "marqueur de retrait absent")
        XCTAssertTrue(app.staticTexts["contexte inchangé"].exists)
    }

    /// B8 — la sortie d'un terminal est présente et sélectionnable.
    func testTerminalOutputIsPresentAndSelectable() {
        launch("thread-blocks")

        let output = app.staticTexts["SORTIE DU TERMINAL — 1 failed, 12 passed."]
        XCTAssertTrue(output.waitForExistence(timeout: 10))
        XCTAssertTrue(output.isHittable)
        assertInsideScreen(output, inset: 8)
    }

    /// B9 — le bouton de copie d'un bloc de code existe et se touche.
    ///
    /// Ce que le presse-papiers reçoit ne se lit pas depuis un test d'interface :
    /// ce qui est vérifié ici est qu'il y a bien un bouton, qu'il est atteignable
    /// et que le toucher ne perturbe pas le fil.
    func testCodeBlockCopyButtonIsReachableAndHarmless() {
        launch("thread-blocks")

        let copy = element("copy-code")
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        XCTAssertTrue(copy.isHittable)

        let code = app.staticTexts["stream.finish()"]
        XCTAssertTrue(code.exists)
        let before = code.frame

        copy.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(code.exists)
        XCTAssertEqual(code.frame.minY, before.minY, accuracy: 1)
    }

    /// B10 — les images d'une demande s'affichent au-dessus de son texte.
    ///
    /// Sans l'image dans le fil, on relit une question qui parle d'un « ça »
    /// disparu.
    func testMessageImagesAppearAboveTheirText() {
        launch("thread-blocks")

        let image = element("message-image")
        XCTAssertTrue(scrollUpTo(image), "aucune image dans la demande")
        let text = app.staticTexts["Voici la capture du plantage."]
        XCTAssertTrue(text.exists)
        XCTAssertLessThan(
            image.frame.maxY, text.frame.midY,
            "l'image devrait précéder le texte de la demande"
        )
        assertInsideScreen(image, inset: 8)
    }
}
