import XCTest

/// Le formulaire de connexion dans chacun de ses états.
///
/// Deux d'entre eux n'existent que le temps d'un aller-retour avec le serveur —
/// le bouton qui travaille, le jeton refusé — et c'est précisément là qu'un
/// défaut coûte cher : l'utilisateur ne peut plus rien faire d'autre.
@MainActor
final class ConnectionScreenMoreTests: HublotUITestCase {

    /// C3 — un seul champ rempli ne suffit pas.
    ///
    /// Le bouton reste inactif tant que l'un des deux manque, dans un sens comme
    /// dans l'autre : `isConfigured` exige les deux, et un test qui n'en
    /// remplirait qu'un ne le prouverait qu'à moitié.
    func testOneFilledFieldIsNotEnoughToEnableConnection() {
        launch("connection")

        let button = app.buttons["connect-button"]
        let url = app.textFields["connection-url"]
        let token = app.secureTextFields["connection-token"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertFalse(button.isEnabled)

        url.tap()
        url.typeText("ws://127.0.0.1:9")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(button.isEnabled, "l'adresse seule ne doit pas suffire")

        // On efface l'adresse et on ne garde que le jeton : l'autre moitié de la
        // même règle.
        url.tap()
        for _ in 0..<20 { url.typeText(XCUIKeyboardKey.delete.rawValue) }
        token.tap()
        token.typeText("secret")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(button.isEnabled, "le jeton seul ne doit pas suffire")
    }

    /// C6 — le jeton donne un shell root sur le VPS : il reste masqué.
    func testTokenStaysMasked() {
        launch("connection")

        let token = app.secureTextFields["connection-token"]
        XCTAssertTrue(token.waitForExistence(timeout: 5))
        token.tap()
        token.typeText("jeton-tres-secret")

        // Un `SecureField` rend des points ; le texte tapé ne doit apparaître ni
        // dans sa valeur, ni ailleurs à l'écran.
        let value = token.value as? String ?? ""
        XCTAssertFalse(value.contains("jeton-tres-secret"), "vu : \(value)")
        XCTAssertFalse(value.isEmpty, "le champ doit tout de même montrer qu'il est rempli")
        XCTAssertFalse(app.staticTexts["jeton-tres-secret"].exists)
        // Et le champ n'est pas devenu un champ ordinaire au passage.
        XCTAssertFalse(app.textFields["connection-token"].exists)
    }

    /// C7 — faire défiler pendant la saisie retire le clavier.
    ///
    /// `scrollDismissesKeyboard(.interactively)` : sans lui, le clavier reste et
    /// recouvre le bouton qu'on cherche justement à atteindre.
    func testScrollingDismissesTheKeyboard() {
        launch("connection")

        let url = app.textFields["connection-url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap()
        url.typeText("ws://127.0.0.1:9")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))

        // Un balayage rapide ne convient pas : `.interactively` retire le
        // clavier **au rythme du doigt**, en le poussant vers le bas. Il faut
        // donc un vrai tirage lent, tenu jusqu'au contact.
        let scroll = app.scrollViews.firstMatch
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let finish = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0))
        start.press(
            forDuration: 0.1, thenDragTo: finish, withVelocity: .slow,
            thenHoldForDuration: 0.4
        )

        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }

    /// C4 — pendant que la connexion travaille, le bouton le dit et refuse un
    /// second toucher.
    ///
    /// Le relais témoin laisse la poignée de main en suspens : c'est un VPS
    /// injoignable, et l'état dure aussi longtemps qu'on le regarde.
    func testBusyButtonAnnouncesItselfAndRefusesASecondTap() {
        launch("connection-busy")

        let button = app.buttons["connect-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        expect(button, toContain: "Connexion…", timeout: 10)
        XCTAssertFalse(button.isEnabled)

        // Le toucher ne doit rien déclencher : ni erreur, ni changement d'écran.
        button.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        expect(button, toContain: "Connexion…")
        XCTAssertFalse(button.isEnabled)
        XCTAssertTrue(app.textFields["connection-url"].exists)
    }

    /// C5 — un jeton refusé s'écrit sous les champs, et remontre le formulaire.
    ///
    /// C'est le seul refus qui doive ramener ici : tout le reste est une panne
    /// passagère, et renvoyer vers un formulaire déjà bien rempli n'aide
    /// personne.
    func testRejectedTokenIsWrittenUnderTheFields() {
        launch("connection-failure")

        let failure = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Jeton refusé'")
        ).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 15), "aucune panne annoncée")

        let button = app.buttons["connect-button"]
        XCTAssertTrue(button.exists)
        // Le formulaire reste utilisable : la panne n'est pas une impasse.
        XCTAssertTrue(button.isEnabled)
        expect(button, toContain: "Se connecter")
    }
}
