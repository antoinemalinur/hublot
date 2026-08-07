//
//  MarkdownStream.swift
//  Hublot
//
//  MarkdownUI reparse **toute** la chaîne à chaque changement. En streaming,
//  une réponse de 20 000 caractères arrivant par morceaux coûte donc un travail
//  quadratique, et l'écran finit par ramer alors que le texte, lui, est fini.
//
//  On coupe le texte accumulé sur frontière de bloc et on ne garde vivant que
//  le dernier. Les blocs figés sont rendus une fois et mémoïsés par identité.
//
//  C'est le raisonnement de `render.py:_cut` — ne jamais couper à l'intérieur
//  d'une construction — appliqué à la performance plutôt qu'à la longueur.
//

import Foundation

nonisolated struct MarkdownStream: Sendable {

    /// Un morceau de Markdown dont on sait qu'il ne changera plus.
    nonisolated struct Block: Identifiable, Sendable, Hashable {
        let id: Int
        let text: String
    }

    /// Les blocs figés, dans l'ordre. Leur identité est stable : SwiftUI ne les
    /// reconstruit pas quand un morceau arrive.
    private(set) var blocks: [Block] = []

    /// Le bloc en cours d'écriture. C'est le seul qui se re-rende.
    private(set) var tail = ""

    private var nextID = 0

    init(_ initial: String = "") {
        append(initial)
    }

    /// Le texte complet, tel qu'il a été reçu.
    ///
    /// La reconstitution doit être exacte au caractère près : c'est ce qu'on
    /// copie quand l'utilisateur sélectionne la réponse.
    var text: String {
        blocks.map(\.text).joined() + tail
    }

    var isEmpty: Bool { blocks.isEmpty && tail.isEmpty }

    mutating func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        tail += chunk
        settle()
    }

    /// Fige tout ce qui peut l'être : appelé à la fin d'un tour, quand plus rien
    /// n'arrivera.
    mutating func finish() {
        guard !tail.isEmpty else { return }
        blocks.append(Block(id: nextID, text: tail))
        nextID += 1
        tail = ""
    }

    // MARK: Découpe

    /// Déplace vers `blocks` tout ce qui précède la dernière frontière sûre.
    ///
    /// Une frontière est une ligne vide **hors clôture de code**. Un bloc de
    /// code ouvert et non refermé n'est jamais figé : ses lignes vides
    /// appartiennent au code, pas au document.
    private mutating func settle() {
        var searchStart = tail.startIndex
        var inFence = false
        var lastBoundary: String.Index?

        while searchStart < tail.endIndex {
            let lineEnd = tail[searchStart...].firstIndex(of: "\n") ?? tail.endIndex
            let line = tail[searchStart..<lineEnd]

            // Une ligne incomplète — pas encore de saut de ligne — ne peut rien
            // décider : le morceau suivant peut la transformer en clôture.
            guard lineEnd < tail.endIndex else { break }

            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
            } else if !inFence, line.allSatisfy(\.isWhitespace) {
                lastBoundary = tail.index(after: lineEnd)
            }

            searchStart = tail.index(after: lineEnd)
        }

        guard let boundary = lastBoundary, boundary > tail.startIndex else { return }
        blocks.append(Block(id: nextID, text: String(tail[..<boundary])))
        nextID += 1
        tail = String(tail[boundary...])
    }
}
