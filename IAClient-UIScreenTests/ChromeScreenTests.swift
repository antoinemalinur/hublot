import XCTest

/// Le chrome haut, et ce que le fil fait pendant qu'une réponse s'écrit.
///
/// Ces éléments sont la seule différence entre « ça travaille » et « c'est
/// mort ». Deux bugs coûteux du projet y sont nés : une conversation coupée en
/// plein tour ressemblait exactement à une conversation lente, et une réponse
/// qui tombait pendant qu'on relisait ramenait la lecture en bas de force.
@MainActor
final class ChromeScreenTests: HublotUITestCase {

    /// F8 — la capsule de plan compte les jalons et les déplie au toucher.
    func testPlanCapsuleCountsMilestonesAndUnfoldsThem() {
        launch("chrome-plan")

        let capsule = element("plan-capsule")
        XCTAssertTrue(capsule.waitForExistence(timeout: 10))
        // Deux franchis sur quatre : le compteur est calculé, pas écrit.
        expect(capsule, toContain: "2/4")

        let milestone = app.staticTexts["Relever l'inventaire des gestes"]
        XCTAssertFalse(milestone.exists, "le plan doit être replié par défaut")

        capsule.tap()
        XCTAssertTrue(milestone.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Vérifier chaque test par mutation"].exists)
        expect(capsule, toContain: "2/4")

        capsule.tap()
        XCTAssertTrue(milestone.waitForNonExistence(timeout: 5))
    }

    /// F9 — plus de battement depuis vingt secondes : la liaison s'est tue.
    ///
    /// Le relais bat toutes les quatre secondes. Vingt sans un mot ne sont donc
    /// pas une lenteur du moteur, et la capsule doit cesser de raconter ce qu'il
    /// faisait la dernière fois qu'on l'a entendu.
    func testActivityCapsuleAnnouncesTheMissingSignal() {
        launch("chrome-lost")

        let activity = element("activity-capsule")
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        expect(activity, toContain: "sans signal", timeout: 10)
        // Et surtout plus le verbe d'avant : il décrirait un travail dont
        // personne ne sait s'il a lieu.
        XCTAssertFalse(plainLabel(of: activity).contains("exécute"), activity.label)
    }

    /// F10 — le moteur se tait depuis une minute, mais la liaison vit.
    ///
    /// C'est l'autre moitié du même écran : on a le droit de s'inquiéter, sans
    /// affirmer que le moteur est mort.
    func testActivityCapsuleCountsTheEngineSilence() {
        launch("chrome-quiet")

        let activity = element("activity-capsule")
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        expect(activity, toContain: "silence 1:", timeout: 10)
        XCTAssertFalse(plainLabel(of: activity).contains("sans signal"), activity.label)
    }

    /// F11 — une liaison qui se refait le dit, à la place des mesures.
    ///
    /// Quand elle se taisait, on attendait devant une réponse qui n'arrivait
    /// plus, sans rien pour distinguer la panne de la lenteur.
    func testReconnectingBannerReplacesTheMeasurements() {
        launch("chrome-reconnecting")

        let banner = element("reconnecting-banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        expect(banner, toContain: "reprise de la liaison")
        // La barre de mesures cède la place : les deux ne partagent pas la ligne.
        assertAbsent(element("status-bar"))
        // Un seul élément porte le bandeau — le glyphe et le texte comptent
        // pour un.
        XCTAssertEqual(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == 'reconnecting-banner'")
            ).count, 1
        )
    }

    /// F12 — sans la moindre mesure, la barre disparaît au lieu de rester vide.
    ///
    /// Une ligne de tirets n'apprend rien et occupe la place de ce qu'on vient
    /// lire.
    func testStatusBarIsAbsentRatherThanEmpty() {
        launch("chrome-silent")

        // L'écran est bien là : c'est la barre, et elle seule, qui manque.
        XCTAssertTrue(element("conversation-back").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Le moteur travaille."].exists)
        assertAbsent(element("status-bar"))
        assertAbsent(element("activity-capsule"), settle: 0)
    }

    /// F13 — en bas du fil, un nouveau tour se montre tout seul.
    func testThreadFollowsANewTurnWhenReadingAtTheBottom() {
        launch("thread-growing")

        let last = app.staticTexts["TOUR DIX — dernier tour avant l'arrivée."]
        XCTAssertTrue(last.waitForExistence(timeout: 10))
        XCTAssertTrue(last.isHittable)

        let arriving = app.staticTexts["TOUR ONZE — arrivé après l'affichage."]
        XCTAssertFalse(arriving.exists, "le tour ne doit pas être là avant son heure")
        XCTAssertTrue(arriving.waitForExistence(timeout: 15))
        XCTAssertTrue(arriving.isHittable, "le fil devrait avoir suivi jusqu'à lui")
    }

    /// F14 — après avoir défilé vers le haut, la lecture ne saute pas.
    ///
    /// C'est le geste qui rendait une longue réponse illisible : on remontait
    /// pour relire, et le tour suivant ramenait l'écran en bas.
    func testThreadDoesNotJumpWhenATurnArrivesWhileReadingHigherUp() {
        // Le tour ne doit pas tomber pendant qu'on se place, sinon ce test
        // observerait l'arrivée au lieu de la lecture. Deux balayages suffisent
        // à quitter le bas du fil ; le délai leur laisse le double du temps
        // qu'ils prennent sous quatre simulateurs en parallèle.
        launch("thread-growing", extraArguments: ["-HublotGrowingDelay", "14"])

        let thread = app.scrollViews.firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        for _ in 0..<2 { thread.swipeDown() }

        // Le repère : un tour ancien, visible là où on s'est arrêté.
        let anchor = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Demande '")
        ).firstMatch
        XCTAssertTrue(anchor.waitForExistence(timeout: 5))
        let before = anchor.frame
        let arriving = app.staticTexts["TOUR ONZE — arrivé après l'affichage."]
        XCTAssertFalse(arriving.exists, "le tour est tombé avant qu'on se soit placé")

        // Le tour tombe pendant qu'on lit ailleurs. On ne peut pas l'attendre à
        // l'écran : s'il fait ce qu'il doit, il naît hors du champ, et une vue
        // hors champ n'existe pas dans un `LazyVStack`. C'est le retour au
        // direct, plus bas, qui prouvera qu'il est bien arrivé.
        RunLoop.current.run(until: Date().addingTimeInterval(17))

        XCTAssertTrue(anchor.exists, "le repère a disparu de l'écran")
        XCTAssertEqual(
            anchor.frame.minY, before.minY, accuracy: 2,
            "la lecture a sauté"
        )

        // Et le tour est bien arrivé : le retour au direct le prouve.
        let jump = element("jump-to-latest")
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        jump.tap()
        XCTAssertTrue(arriving.waitForExistence(timeout: 5))
    }
}
