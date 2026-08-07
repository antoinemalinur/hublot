//
//  HighlightedCode.swift
//  Hublot
//
//  Coloration syntaxique des blocs de code. C'est l'une des deux choses que
//  Telegram ne peut pas faire (l'autre étant les tableaux) et donc l'une des
//  deux raisons d'être de cette app.
//

import Highlightr
import SwiftUI

// MARK: - Moteur

/// Enveloppe autour de Highlightr (highlight.js sous JavaScriptCore).
///
/// L'instance est unique et vit sur le `MainActor` : construire un `Highlightr`
/// démarre un contexte JavaScript et charge la grammaire, ce qui est cher. Le
/// coût réel du surlignage sera mesuré, pas estimé (cf. §5 du plan).
@MainActor
final class SyntaxHighlighter {
    static let shared = SyntaxHighlighter()

    private let engine: Highlightr?
    private let supported: Set<String>
    private var cache: [CacheKey: AttributedString] = [:]

    /// Les alias que les moteurs écrivent en pratique dans leurs clôtures de
    /// bloc, mais que highlight.js ne connaît pas sous ce nom.
    private static let aliases: [String: String] = [
        "sh": "bash",
        "shell": "bash",
        "zsh": "bash",
        "js": "javascript",
        "ts": "typescript",
        "jsx": "javascript",
        "tsx": "typescript",
        "py": "python",
        "yml": "yaml",
        "md": "markdown",
        "rs": "rust",
        "kt": "kotlin",
        "objc": "objectivec",
        "h": "objectivec",
        "docker": "dockerfile",
        "jsonc": "json",
        "jsonl": "json",
    ]

    private struct CacheKey: Hashable {
        let code: String
        let language: String?
    }

    private init() {
        engine = Highlightr()
        // Gruvbox est le seul thème sombre de la liste dont la palette soit
        // chaude : ocre, olive, brique. Il cohabite avec le laiton de l'accent
        // au lieu de le contredire, là où atom-one-dark tire vers le violet et
        // fait ressembler chaque bloc de code à une pièce rapportée.
        engine?.setTheme(to: "gruvbox-dark-soft")
        engine?.theme.codeFont = UIFont.monospacedSystemFont(
            ofSize: Hublot.monoSize, weight: .regular
        )
        supported = Set(engine?.supportedLanguages() ?? [])
    }

    /// Rend `code` colorié. Renvoie du texte nu si la langue est inconnue ou si
    /// le moteur échoue : on ne perd jamais le contenu, on perd la couleur.
    func highlight(_ code: String, language: String?) -> AttributedString {
        let key = CacheKey(code: code, language: language)
        if let hit = cache[key] { return hit }

        let result = render(code, language: language)

        // En streaming, chaque chunk produit une chaîne différente : sans borne
        // le cache grossirait indéfiniment sur une longue session.
        if cache.count > 256 { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        return result
    }

    private func render(_ code: String, language: String?) -> AttributedString {
        var plain = AttributedString(code)
        plain.font = .hublotMono
        plain.foregroundColor = Hublot.prose

        guard let engine, let resolved = resolve(language) else { return plain }
        // `fastRender` évite le passage par le parseur HTML de Highlightr.
        guard let highlighted = engine.highlight(code, as: resolved, fastRender: true) else {
            return plain
        }
        return AttributedString(highlighted)
    }

    /// Normalise l'étiquette de langue vers un nom que highlight.js connaît.
    /// `nil` signifie « pas de coloration » — jamais de détection automatique,
    /// qui coûte cher et se trompe sur les extraits courts.
    private func resolve(_ language: String?) -> String? {
        guard let language, !language.isEmpty else { return nil }
        let lower = language.lowercased()
        let canonical = Self.aliases[lower] ?? lower
        return supported.contains(canonical) ? canonical : nil
    }
}

// MARK: - Vue

/// Le contenu colorié d'un bloc de code, sans décor : l'encadrement, l'en-tête
/// et le défilement horizontal appartiennent à `CodeBlockView`.
struct HighlightedCode: View {
    let code: String
    let language: String?

    var body: some View {
        Text(SyntaxHighlighter.shared.highlight(code, language: language))
            .font(.hublotMono)
            .lineSpacing(Hublot.monoLine - Hublot.monoSize)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
    }
}
