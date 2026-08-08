//
//  Blocks.swift
//  Hublot
//
//  Les blocs du fil. Chacun s'annonce par un glyphe en gouttière ; tout ce qui
//  n'est pas de la prose tient sur une ligne tant qu'on ne le déplie pas.
//

import MarkdownUI
import SwiftUI
import UIKit

// MARK: - Gouttière

/// La colonne de 28 pt à gauche de tout. Elle porte l'état, comme la marge
/// d'un `git log` : l'œil descend une colonne au lieu de chasser des badges.
struct Gutter<Glyph: View, Content: View>: View {
    @ViewBuilder var glyph: () -> Glyph
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            glyph()
                .frame(width: Hublot.gutter, height: Hublot.proseLine)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Aiguillage

struct TurnRow: View {
    let turn: Turn

    var body: some View {
        switch turn {
        case .user(let t): UserBlock(turn: t)
        case .assistant(let t): AssistantBlock(turn: t)
        case .thought(let t): ThoughtBlock(turn: t)
        case .toolCall(let t): ToolCallCard(turn: t)
        case .permission(let t): PermissionCard(turn: t)
        case .notice(let t): NoticeLine(turn: t)
        }
    }
}

/// Une ligne du fil rendu : un tour ordinaire, ou une suite d'outils repliée.
struct ThreadRowView: View {
    let row: ThreadRow

    var body: some View {
        switch row {
        case .single(let turn): TurnRow(turn: turn)
        case .tools(let group):
            // Un appel isolé n'a rien à replier : il s'affiche tel quel, sinon
            // on paierait un pli pour une seule ligne.
            if group.calls.count == 1 {
                ToolCallCard(turn: group.calls[0])
            } else {
                ToolGroupCard(group: group)
            }
        }
    }
}

/// Une suite d'appels de même nature, en une ligne.
///
/// Repliée par défaut — c'est le sens même du groupe : ne pas noyer la réponse
/// sous vingt lignes de plomberie. Un toucher rouvre tout, dans l'ordre et
/// **sans rien fusionner** : si Claude a modifié six fois le même fichier, on
/// veut voir six lignes, parce que ce sont six modifications différentes.
struct ToolGroupCard: View {
    let group: ToolGroup

    @State private var isExpanded = false

    private var summary: String {
        let targets = group.targets
        guard !targets.isEmpty else { return "" }
        return targets.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Hublot.unit) {
            Gutter {
                StatusGlyph(status: group.status)
            } content: {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Hublot.unit) {
                        Text(group.kind.rawValue.capitalized)
                            .font(.hublotMetaEmphasis)
                            .foregroundStyle(Hublot.meta)
                        Text("×\(group.calls.count)")
                            .font(.hublotMetaEmphasis)
                            .foregroundStyle(Hublot.ember)
                        Text(summary)
                            .font(.hublotMono)
                            .foregroundStyle(Hublot.prose)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Hublot.unit)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Hublot.meta)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(group.kind.rawValue), \(group.calls.count) appels, \(summary)"
                )
                .accessibilityHint(isExpanded ? "Replier le détail" : "Voir chaque appel")
                .accessibilityIdentifier("tool-group-\(group.kind.rawValue)")
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: Hublot.unit * 1.5) {
                    ForEach(group.calls) { call in
                        ToolCallCard(turn: call)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
    }
}

// MARK: - Note de marge

/// Discrète par construction : c'est un fait de service, pas une réponse. Même
/// gouttière que tout le reste, pour que l'œil ne quitte pas sa colonne.
struct NoticeLine: View {
    let turn: NoticeTurn

    var body: some View {
        Gutter {
            Image(systemName: turn.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Hublot.meta)
        } content: {
            Text(turn.text)
                .font(.hublotMeta)
                .foregroundStyle(Hublot.meta)
                .frame(height: Hublot.proseLine, alignment: .leading)
        }
    }
}

// MARK: - Message de l'utilisateur

/// Pas de bulle. Un filet accentué, et le texte au même endroit que la prose de
/// l'agent : c'est la même conversation, pas deux camps.
struct UserBlock: View {
    let turn: UserTurn

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Le filet du message reprend la braise du rail : c'est le même
            // feu, allumé là où l'utilisateur a parlé.
            Rectangle()
                .fill(Hublot.ember)
                .frame(width: 2)
                .shadow(color: Hublot.ember.opacity(0.5), radius: 4)
                .frame(width: Hublot.gutter)
            VStack(alignment: .leading, spacing: Hublot.unit) {
                if !turn.images.isEmpty {
                    // Ce qu'on a montré fait partie de ce qu'on a dit : sans
                    // l'image dans le fil, on relit une question qui parle
                    // d'un « ça » disparu.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Hublot.unit) {
                            ForEach(Array(turn.images.enumerated()), id: \.offset) { _, data in
                                AttachedImage(data: data, side: 96)
                            }
                        }
                    }
                    .scrollClipDisabled()
                }
                if !turn.text.isEmpty {
                    Text(turn.text)
                        .font(.hublotProse)
                        .foregroundStyle(Hublot.prose)
                        .lineSpacing(Hublot.proseLine - Hublot.proseSize)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Une image du fil ou du composer, au même carré arrondi partout.
///
/// Le décodage est fait une fois, à la construction : dans un `LazyVStack` la
/// vue est reconstruite à chaque défilement, et refaire un `UIImage(data:)` à
/// chaque passe fait tomber la fréquence d'affichage dès la deuxième capture
/// d'écran jointe.
struct AttachedImage: View {
    private let decoded: UIImage?
    private let side: CGFloat

    init(data: Data, side: CGFloat = 96) {
        self.decoded = UIImage(data: data)
        self.side = side
    }

    var body: some View {
        Group {
            if let decoded {
                Image(uiImage: decoded)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Hublot.surface)
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: Hublot.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Hublot.radius, style: .continuous)
                .strokeBorder(Hublot.rule, lineWidth: 1)
        }
    }
}

// MARK: - Réponse de l'agent

struct AssistantBlock: View {
    let turn: AssistantTurn

    var body: some View {
        Gutter {
            if turn.isStreaming {
                StreamingCursor()
            } else {
                Circle()
                    .fill(Hublot.meta)
                    .frame(width: 3, height: 3)
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                // Un rendu par bloc figé, avec une identité stable : SwiftUI ne
                // reconstruit que la queue quand un morceau arrive. Rendre
                // `turn.markdown` d'un seul tenant ferait reparser toute la
                // réponse à chaque chunk.
                ForEach(turn.stream.blocks) { block in
                    ProseBlock(markdown: block.text)
                }
                if !turn.stream.tail.isEmpty {
                    ProseBlock(markdown: turn.stream.tail)
                }
            }
        }
    }
}

/// Un fragment de prose. Isolé dans sa propre vue pour que SwiftUI puisse le
/// considérer inchangé et sauter son rendu.
struct ProseBlock: View, Equatable {
    let markdown: String

    var body: some View {
        Markdown(markdown)
            .markdownTheme(.hublot)
            // Sans ça, les puces imbriquées se font tronquer au lieu de passer
            // à la ligne : MarkdownUI mesure la largeur de ses marqueurs en
            // deux passes, et dans un `LazyVStack` la première passe propose
            // une largeur qui n'est pas la bonne.
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Le curseur de streaming. Il bat pour dire que ça travaille encore ; il
/// disparaît au `stopReason`.
struct StreamingCursor: View {
    @State private var on = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Hublot.ember)
            .frame(width: 2, height: 15)
            .shadow(color: Hublot.ember.opacity(0.8), radius: 5)
            .opacity(on ? 1 : 0.15)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: on)
            .onAppear { on = false }
    }
}

// MARK: - Raisonnement

struct ThoughtBlock: View {
    let turn: ThoughtTurn
    @State private var isExpanded = false

    private var caption: String {
        guard let duration = turn.duration else { return "raisonnement" }
        return String(format: "raisonnement · %.1f s", Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18)
    }

    var body: some View {
        Gutter {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Hublot.meta)
        } content: {
            VStack(alignment: .leading, spacing: Hublot.unit) {
                Button { withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() } } label: {
                    HStack {
                        Text(caption)
                            .font(.hublotMeta)
                            .foregroundStyle(Hublot.meta)
                        Spacer()
                    }
                    .frame(height: Hublot.proseLine)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Markdown(turn.markdown)
                        .markdownTheme(.hublot)
                        .markdownTextStyle(\.text) { ForegroundColor(Hublot.meta) }
                        .padding(.leading, Hublot.unit)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Hublot.rule).frame(width: 1)
                        }
                }
            }
        }
    }
}

// MARK: - Appel d'outil

struct ToolCallCard: View {
    let turn: ToolCallTurn
    @State private var isExpanded: Bool

    init(turn: ToolCallTurn) {
        self.turn = turn
        // Un échec s'ouvre tout seul : c'est la seule fois où l'on veut voir le
        // détail sans le demander.
        _isExpanded = State(initialValue: turn.isExpanded || turn.status == .failed)
    }

    var body: some View {
        Gutter {
            StatusGlyph(status: turn.status)
        } content: {
            VStack(alignment: .leading, spacing: Hublot.unit) {
                Button { withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Hublot.unit) {
                        Text(turn.kind.rawValue.capitalized)
                            .font(.hublotMetaEmphasis)
                            .foregroundStyle(Hublot.meta)
                        // Replié, la ligne tient dans sa hauteur. Déplié, le
                        // titre s'affiche en entier : sur un `execute`, c'est
                        // la commande exacte, et la tronquer revient à cacher
                        // ce qui a été fait.
                        Text(turn.title)
                            .font(.hublotMono)
                            .foregroundStyle(Hublot.prose)
                            .lineLimit(isExpanded ? nil : 1)
                            .truncationMode(turn.kind == .execute ? .tail : .middle)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: Hublot.unit)
                        // Pas de chevron ici : le glyphe de statut en gouttière
                        // dit déjà que c'est un bloc machine, et toute la ligne
                        // est tactile. Une flèche de plus n'ajouterait qu'un
                        // cinquième élément à lire.
                        if let detail = turn.detail {
                            Text(detail)
                                .font(.hublotMeta)
                                .foregroundStyle(
                                    turn.status == .failed ? Hublot.failed : Hublot.meta
                                )
                        }
                    }
                    .frame(minHeight: Hublot.proseLine)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tool-call-\(turn.id)")

                if isExpanded {
                    ForEach(turn.content) { item in
                        ToolContentView(content: item)
                    }
                }
            }
        }
    }
}

struct StatusGlyph: View {
    let status: ToolStatus

    var body: some View {
        Group {
            switch status {
            case .pending:
                Circle().strokeBorder(Hublot.meta, lineWidth: 1).frame(width: 7, height: 7)
            case .inProgress:
                Circle()
                    .fill(Hublot.ember)
                    .frame(width: 7, height: 7)
                    .shadow(color: Hublot.ember.opacity(0.9), radius: 5)
            case .completed:
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Hublot.meta)
            case .failed:
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Hublot.failed)
            }
        }
    }
}

struct ToolContentView: View {
    let content: ToolContent

    var body: some View {
        switch content {
        case .text(_, let markdown):
            Markdown(markdown)
                .markdownTheme(.hublot)
        case .diff(_, let path, let oldText, let newText):
            DiffView(path: path, oldText: oldText, newText: newText)
        case .terminal(_, let output):
            TerminalOutput(text: output)
        }
    }
}

/// La sortie d'un terminal n'est pas du code source : la colorer comme du bash
/// invente une syntaxe qui n'existe pas et rend un message d'erreur bariolé et
/// moins lisible, pas plus. Monospace, une seule couleur.
struct TerminalOutput: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.hublotMono)
                .foregroundStyle(Hublot.prose.opacity(0.85))
                .lineSpacing(Hublot.monoLine - Hublot.monoSize)
                .textSelection(.enabled)
                .padding(Hublot.unit * 1.5)
        }
        .trailingScrollFade()
        .background(Hublot.surface)
        .clipShape(RoundedRectangle(cornerRadius: Hublot.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Hublot.radius, style: .continuous)
                .strokeBorder(Hublot.rule, lineWidth: 1)
        )
    }
}

// MARK: - Diff

struct DiffView: View {
    let path: String
    let oldText: String?
    let newText: String

    private var lines: [DiffLine] {
        DiffLine.unified(
            old: (oldText ?? "").isEmpty ? [] : (oldText ?? "").components(separatedBy: "\n"),
            new: newText.components(separatedBy: "\n")
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(path)
                .font(.hublotMeta)
                .foregroundStyle(Hublot.meta)
                .padding(.horizontal, Hublot.unit * 1.5)
                .padding(.vertical, Hublot.unit)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(spacing: Hublot.unit) {
                            Text(line.kind.marker)
                                .font(.hublotMono)
                                .foregroundStyle(line.kind.color)
                                .frame(width: 10, alignment: .leading)
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.hublotMono)
                                .foregroundStyle(
                                    line.kind == .context ? Hublot.meta : Hublot.prose
                                )
                        }
                        .padding(.horizontal, Hublot.unit * 1.5)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.kind.background)
                    }
                }
                .padding(.bottom, Hublot.unit)
            }
        }
        .background(Hublot.surface)
        .clipShape(RoundedRectangle(cornerRadius: Hublot.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Hublot.radius, style: .continuous)
                .strokeBorder(Hublot.rule, lineWidth: 1)
        )
    }
}

struct DiffLine: Identifiable {
    enum Kind {
        case context, added, removed

        var marker: String {
            switch self {
            case .context: " "
            case .added: "+"
            case .removed: "−"
            }
        }

        var color: Color {
            switch self {
            case .context: Hublot.meta
            case .added: Hublot.added
            case .removed: Hublot.removed
            }
        }

        var background: Color {
            switch self {
            case .context: .clear
            case .added: Hublot.added.opacity(0.08)
            case .removed: Hublot.removed.opacity(0.08)
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let text: String

    /// Diff unifié à partir de `CollectionDifference` — la bibliothèque
    /// standard suffit, aucune dépendance à ajouter pour ça.
    static func unified(old: [String], new: [String]) -> [DiffLine] {
        let difference = new.difference(from: old)
        var removed = Set<Int>()
        var inserted: [Int: String] = [:]
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, let element, _): inserted[offset] = element
            }
        }

        var result: [DiffLine] = []
        var newOffset = 0
        for (oldOffset, line) in old.enumerated() {
            while let insertion = inserted[newOffset] {
                result.append(DiffLine(kind: .added, text: insertion))
                newOffset += 1
            }
            if removed.contains(oldOffset) {
                result.append(DiffLine(kind: .removed, text: line))
            } else {
                result.append(DiffLine(kind: .context, text: line))
                newOffset += 1
            }
        }
        while let insertion = inserted[newOffset] {
            result.append(DiffLine(kind: .added, text: insertion))
            newOffset += 1
        }
        return result
    }
}

// MARK: - Permission

/// En ligne, jamais en modale : une modale masque le contexte au moment précis
/// où il faut le lire pour décider.
struct PermissionCard: View {
    let turn: PermissionTurn
    @State private var chosen: String?

    init(turn: PermissionTurn) {
        self.turn = turn
        _chosen = State(initialValue: turn.chosen)
    }

    var body: some View {
        Gutter {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Hublot.ember)
                .shadow(color: Hublot.ember.opacity(0.6), radius: 5)
        } content: {
            VStack(alignment: .leading, spacing: Hublot.unit * 1.25) {
                HStack(spacing: Hublot.unit) {
                    Text("Autoriser")
                        .font(.hublotMetaEmphasis)
                        .foregroundStyle(Hublot.ember)
                    Text(turn.toolTitle)
                        .font(.hublotMono)
                        .foregroundStyle(Hublot.prose)
                    Spacer()
                }
                .frame(height: Hublot.proseLine)

                // Ce que l'agent s'apprête vraiment à faire. Sans ça,
                // autoriser est un acte aveugle.
                Text(turn.detail)
                    .font(.hublotMono)
                    .foregroundStyle(Hublot.prose)
                    .textSelection(.enabled)
                    .padding(Hublot.unit * 1.25)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Hublot.surface, in: .rect(cornerRadius: Hublot.radius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Hublot.radius)
                            .strokeBorder(Hublot.ember.opacity(0.4), lineWidth: 1)
                    )

                if let settled = turn.options.first(where: { $0.id == chosen }) {
                    // Une fois tranché, la question ne se repose pas : les
                    // boutons cèdent la place au verdict, dans les mots mêmes
                    // du bouton qui a été pressé.
                    Label(settled.name, systemImage: settled.kind.isRejection
                        ? "xmark.circle" : "checkmark.circle")
                        .font(.hublotMetaEmphasis)
                        .foregroundStyle(settled.kind.isRejection ? Hublot.meta : Hublot.ember)
                } else {
                    // Les libellés viennent de l'agent, jamais codés en dur.
                    HStack(spacing: Hublot.unit) {
                        ForEach(turn.options) { option in
                            Button(option.name) {
                                withAnimation(.snappy(duration: 0.2)) { chosen = option.id }
                                // L'agent attend cette réponse pour reprendre.
                                if let respond = turn.respond {
                                    Task { await respond(option.id) }
                                }
                            }
                            .font(.hublotMetaEmphasis)
                            .buttonStyle(.glass)
                            .tint(option.kind.isRejection ? Hublot.meta : Hublot.ember)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}
