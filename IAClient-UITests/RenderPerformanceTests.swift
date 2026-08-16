//
//  RenderPerformanceTests.swift
//  Hublot
//
//  La question que le plan pose : rendre toute la réponse à chaque morceau
//  coûte-t-il vraiment un travail quadratique, et la découpe le supprime-t-elle ?
//
//  On mesure les deux stratégies sur le même contenu, dans les mêmes
//  conditions, et on imprime les chiffres. Ils vont dans le rapport tels quels.
//

import Foundation
import MarkdownUI
import SwiftUI
import Testing

@testable import IAClient_UI

@MainActor
@Suite("Coût du rendu en streaming", .serialized)
struct RenderPerformanceTests {

    /// Un document réaliste : de la prose, une liste, un tableau, du code.
    /// Répété jusqu'à la taille voulue.
    private static func document(characters target: Int) -> String {
        let unit = """
            Telegram n'a **aucune primitive de tableau**, donc `render.py` simule \
            des colonnes en monospace et bascule en fiches au-delà de 44 caractères.

            | Construction | Telegram | Hublot |
            | --- | --- | --- |
            | Tableau GFM | simulé | natif |
            | Code coloré | non | 185 langages |

            1. La transformation coûte **zéro token**.
            2. Le modèle émet le même Markdown partout.

            ```swift
            func highlightCode(_ code: String, language: String?) -> Text {
                Text(code)
            }
            ```


            """
        var text = ""
        while text.count < target { text += unit }
        return String(text.prefix(target))
    }

    /// Rend une vue hors écran et attend que la mise en page soit faite.
    /// `ImageRenderer` exerce l'analyse Markdown et la mise en page — la partie
    /// quadratique — même s'il ne dit rien du compositing.
    private func render(_ view: some View) {
        let renderer = ImageRenderer(content: view.frame(width: 390))
        renderer.scale = 1
        _ = renderer.uiImage
    }

    /// Simule l'arrivée d'une réponse par morceaux et renvoie le temps total.
    private func measureStreaming(
        characters: Int, chunks: Int, split: Bool
    ) -> (seconds: Double, blocks: Int) {
        let document = Self.document(characters: characters)
        let size = max(1, document.count / chunks)

        var stream = MarkdownStream()
        var index = document.startIndex
        let start = ContinuousClock.now

        while index < document.endIndex {
            let end = document.index(index, offsetBy: size, limitedBy: document.endIndex)
                ?? document.endIndex
            stream.append(String(document[index..<end]))
            index = end

            if split {
                // Ce que fait l'app : seule la queue se re-rend, les blocs figés
                // sont déjà à l'écran et SwiftUI les saute.
                render(ProseBlock(markdown: stream.tail))
            } else {
                // La version naïve : tout le texte reçu, à chaque morceau.
                render(ProseBlock(markdown: stream.text))
            }
        }

        return (start.duration(to: .now).seconds, stream.blocks.count)
    }

    @Test("La découpe rend le streaming linéaire au lieu de quadratique")
    func coutDuStreaming() {
        var lines: [String] = []
        lines.append("")
        lines.append("  taille   morceaux   entier      découpé     gain   blocs")
        lines.append("  ─────────────────────────────────────────────────────────")

        var worstRatio = 0.0

        // 20 000 caractères faisait dépasser une minute sur certains runners
        // de simulateur et bloquait le MainActor assez longtemps pour faire
        // expirer des tests fonctionnels sans rapport. 8 000 garde largement
        // le signal quadratique tout en restant un test, pas un benchmark de
        // plusieurs minutes.
        for characters in [200, 2_000, 8_000] {
            let chunks = max(4, characters / 100)
            let whole = measureStreaming(characters: characters, chunks: chunks, split: false)
            let split = measureStreaming(characters: characters, chunks: chunks, split: true)
            let ratio = whole.seconds / max(split.seconds, 0.000_001)
            worstRatio = max(worstRatio, ratio)

            lines.append(
                String(
                    format: "  %6d   %8d   %7.0f ms   %7.0f ms   ×%4.1f   %3d",
                    characters, chunks, whole.seconds * 1000, split.seconds * 1000,
                    ratio, split.blocks
                )
            )
        }

        lines.append("")
        print(lines.joined(separator: "\n"))

        // Le seuil est volontairement bas : le test existe pour produire des
        // chiffres et pour attraper une régression franche, pas pour figer une
        // performance qui dépend de la machine.
        #expect(worstRatio > 1.5, "la découpe devrait être nettement plus rapide sur un long flux")
    }

    @Test("La découpe elle-même est négligeable")
    func coutDeLaDecoupe() {
        let document = Self.document(characters: 20_000)
        let start = ContinuousClock.now
        var stream = MarkdownStream()
        var index = document.startIndex
        while index < document.endIndex {
            let end = document.index(index, offsetBy: 100, limitedBy: document.endIndex)
                ?? document.endIndex
            stream.append(String(document[index..<end]))
            index = end
        }
        let elapsed = start.duration(to: .now).seconds

        print(
            String(
                format: "\n  découpe seule : %.1f ms pour 20 000 caractères en %d blocs\n",
                elapsed * 1000, stream.blocks.count
            )
        )
        #expect(stream.text == document)
        #expect(elapsed < 1.0)
    }

    @Test("Cent battements ne révisent pas un historique de mille entrées")
    func heartbeatsLeaveTheDocumentAlone() async throws {
        let harness = try await Harness()
        let chat = await harness.session(id: harness.recordedSession)

        for index in 0..<500 {
            await harness.transport.emit(Self.userFrame(
                session: harness.recordedSession, text: "Question \(index)"
            ))
            await harness.transport.emit(Self.messageFrame(
                session: harness.recordedSession, id: "m-\(index)",
                text: "Réponse \(index).\n\n"
            ))
        }
        await harness.transport.emit(Self.usageFrame(session: harness.recordedSession))
        #expect(await harness.until({ chat.turns.count == 1_000 }, limit: 5_000))

        let revision = chat.documentRevision
        let start = ContinuousClock.now
        for index in 0..<100 {
            await harness.transport.emit(Self.activityFrame(
                session: harness.recordedSession, elapsed: index
            ))
        }
        #expect(await harness.until({ chat.activity?.elapsed == 99 }, limit: 5_000))
        let elapsed = start.duration(to: .now).seconds

        print(String(
            format: "\n  100 battements / 1 000 entrées : %.1f ms, révision %d → %d\n",
            elapsed * 1_000, revision, chat.documentRevision
        ))
        #expect(chat.documentRevision == revision)
        #expect(elapsed < 0.1)

        // Le second verrou : même si le parent recrée la valeur de vue pour un
        // nouveau battement, sa porte Equatable reste fermée à révision égale.
        let pinned = Binding.constant(true)
        let before = ThreadDocument(
            turns: chat.turns, revision: revision, machine: chat.machine,
            isPinned: pinned
        )
        let after = ThreadDocument(
            turns: chat.turns, revision: revision, machine: chat.machine,
            isPinned: pinned
        )
        #expect(before == after)
    }

    private static func userFrame(session: String, text: String) -> String {
        """
        {"jsonrpc":"2.0","method":"session/update","params":{
          "sessionId":"\(session)","update":{"sessionUpdate":"user_message_chunk",
          "content":{"type":"text","text":"\(text)"}}}}
        """
    }

    private static func messageFrame(session: String, id: String, text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\n", with: "\\n")
        return """
            {"jsonrpc":"2.0","method":"session/update","params":{
              "sessionId":"\(session)","update":{"sessionUpdate":"agent_message_chunk",
              "messageId":"\(id)","content":{"type":"text","text":"\(escaped)"}}}}
            """
    }

    private static func usageFrame(session: String) -> String {
        """
        {"jsonrpc":"2.0","method":"session/update","params":{
          "sessionId":"\(session)","update":{"sessionUpdate":"usage_update",
          "used":10,"size":100}}}
        """
    }

    private static func activityFrame(session: String, elapsed: Int) -> String {
        """
        {"jsonrpc":"2.0","method":"session/update","params":{
          "sessionId":"\(session)","update":{"sessionUpdate":"hublot_activity",
          "running":true,"phase":"thinking","elapsed":\(elapsed),"quiet":0}}}
        """
    }
}
