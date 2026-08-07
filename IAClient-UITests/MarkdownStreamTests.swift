//
//  MarkdownStreamTests.swift
//  Hublot
//
//  Le découpage du streaming a une propriété non négociable : quelle que soit
//  la façon dont les morceaux arrivent, le texte reconstitué doit être
//  exactement celui qui a été reçu. Tout le reste — combien de blocs, où ils
//  coupent — n'est qu'une optimisation.
//

import Testing

@testable import IAClient_UI

@Suite("Découpe du flux Markdown")
struct MarkdownStreamTests {

    @Test("Le texte reconstitué est exact, quelle que soit la découpe en morceaux")
    func reconstitutionExacte() {
        let document = """
            Premier paragraphe.

            Deuxième paragraphe avec du `code`.

            ```swift
            let x = 1

            let y = 2
            ```

            Dernier mot.
            """

        // Un caractère à la fois : le pire cas, et celui qui casse les découpes
        // naïves — chaque morceau peut tomber au milieu d'une clôture.
        var oneByOne = MarkdownStream()
        for character in document {
            oneByOne.append(String(character))
        }
        #expect(oneByOne.text == document)

        // Par blocs de 7, pour tomber sur des frontières différentes.
        var bySeven = MarkdownStream()
        var index = document.startIndex
        while index < document.endIndex {
            let end = document.index(index, offsetBy: 7, limitedBy: document.endIndex) ?? document.endIndex
            bySeven.append(String(document[index..<end]))
            index = end
        }
        #expect(bySeven.text == document)

        // D'un seul coup.
        let atOnce = MarkdownStream(document)
        #expect(atOnce.text == document)
    }

    @Test("Une ligne vide dans un bloc de code ne coupe pas")
    func lignesVidesDansLeCode() {
        let document = """
            Avant.

            ```python
            def a():
                pass

            def b():
                pass
            ```

            Après.
            """

        var stream = MarkdownStream()
        for character in document {
            stream.append(String(character))
        }
        stream.finish()

        #expect(stream.text == document)

        // Le bloc de code doit être resté d'une seule pièce : aucun bloc figé
        // ne doit contenir une clôture ouvrante sans sa fermante.
        for block in stream.blocks {
            let fences = block.text.components(separatedBy: "```").count - 1
            #expect(fences % 2 == 0, "bloc coupé au milieu d'une clôture : \(block.text)")
        }
    }

    @Test("Les blocs figés gardent leur identité quand la suite arrive")
    func identitesStables() {
        var stream = MarkdownStream("Un.\n\nDeux.\n\n")
        let first = stream.blocks.map(\.id)
        #expect(!first.isEmpty)

        stream.append("Trois.\n\nQuatre.\n\n")
        let after = stream.blocks.map(\.id)

        // C'est ce qui permet à SwiftUI de ne pas reconstruire ce qui est déjà
        // rendu : les identités déjà émises doivent être un préfixe des
        // nouvelles, jamais renumérotées.
        #expect(Array(after.prefix(first.count)) == first)
        #expect(after.count > first.count)
    }

    @Test("Un bloc de code jamais refermé reste vivant")
    func clotureOuverte() {
        var stream = MarkdownStream("Texte.\n\n```swift\nlet a = 1\n\nlet b = 2\n")
        // Rien après la clôture ouvrante ne peut être figé : le morceau suivant
        // peut encore appartenir au code.
        #expect(stream.tail.contains("```"))
        #expect(!stream.blocks.contains { $0.text.contains("```") })

        stream.append("```\n\nFin.\n")
        #expect(stream.text == "Texte.\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nFin.\n")
    }

    @Test("Un flux vide ne produit rien")
    func fluxVide() {
        var stream = MarkdownStream()
        #expect(stream.isEmpty)
        stream.append("")
        #expect(stream.isEmpty)
        #expect(stream.text.isEmpty)
    }
}
