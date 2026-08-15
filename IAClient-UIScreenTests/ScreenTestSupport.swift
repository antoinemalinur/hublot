import XCTest

/// Les gestes et les attentes que plusieurs écrans partagent.
///
/// Rien ici n'affirme quoi que ce soit sur l'app : ce sont des façons de viser
/// un élément et d'attendre qu'il dise quelque chose. Les assertions restent
/// dans les tests, là où on peut lire ce qu'elles protègent.
extension HublotUITestCase {

    /// Attend qu'un élément porte un libellé contenant `fragment`.
    ///
    /// Les espaces insécables de la typographie française sont ramenés à des
    /// espaces ordinaires des deux côtés : sans ça, « il y a 1 h » écrit au
    /// clavier ne retrouve jamais celui de l'écran, pourtant juste.
    @discardableResult
    func expect(
        _ element: XCUIElement, toContain fragment: String,
        timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var seen = ""
        repeat {
            if element.exists {
                seen = plainLabel(of: element)
                if seen.contains(fragment) { return true }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        } while Date() < deadline
        XCTFail(
            "libellé attendu « \(fragment) », vu « \(seen) »",
            file: file, line: line
        )
        return false
    }

    /// La même normalisation que `plainLabel`, appliquée à une chaîne attendue.
    ///
    /// Les nombres mis en forme par le système portent des espaces insécables
    /// étroits entre leurs milliers : « 58 300 » tapé au clavier ne les
    /// retrouve jamais.
    func normalised(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// Le premier élément dont le libellé contient ce fragment, quel que soit
    /// son type. Utile là où l'app n'expose pas encore d'identifiant.
    func labelled(_ fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", fragment)
        ).firstMatch
    }

    /// Affirme qu'un élément n'apparaît pas — et laisse à l'écran le temps de le
    /// faire apparaître avant de conclure.
    ///
    /// Un `XCTAssertFalse(element.exists)` immédiat passe aussi bien devant un
    /// écran qui n'affiche jamais l'élément que devant un écran qui n'a pas fini
    /// de se construire : il ne prouve donc rien.
    func assertAbsent(
        _ element: XCUIElement, settle: TimeInterval = 1,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        XCTAssertFalse(
            element.exists,
            "élément présent alors qu'il ne devait pas l'être : \(element)",
            file: file, line: line
        )
    }

    /// Lance un scénario avec une taille de caractères accessible.
    ///
    /// C'est le réglage d'un appareil réel réglé pour être lu, et il change
    /// toutes les hauteurs de rangée : ce qui tient sur l'écran du développeur
    /// n'y tient plus forcément.
    func launchWithLargeText(
        _ scenario: String,
        category: String = "UICTContentSizeCategoryAccessibilityL"
    ) {
        launch(scenario, extraArguments: [
            "-UIPreferredContentSizeCategoryName", category,
            "-UIAccessibilityReduceMotionEnabled", "YES",
        ])
    }

    /// Une rangée de dépôt, visée par son nom plutôt que par son sous-titre —
    /// lequel est justement ce que plusieurs tests vérifient.
    func projectRow(_ name: String) -> XCUIElement {
        element("project-row-\(name)")
    }

    /// Une rangée de conversation, visée par son identifiant de session.
    func sessionRow(_ sessionId: String) -> XCUIElement {
        element("session-row-\(sessionId)")
    }

    /// Attend qu'un élément devienne touchable, pas seulement qu'il existe : un
    /// bouton sous une capsule de verre existe bien avant d'accepter un doigt.
    @discardableResult
    func waitUntilHittable(
        _ element: XCUIElement, timeout: TimeInterval = 5,
        file: StaticString = #filePath, line: UInt = #line
    ) -> Bool {
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        let result = XCTWaiter.wait(for: [hittable], timeout: timeout) == .completed
        XCTAssertTrue(result, "jamais touchable : \(element)", file: file, line: line)
        return result
    }
}
