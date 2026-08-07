//
//  Turn.swift
//  Hublot
//
//  Le modèle de la conversation. Les noms et les valeurs suivent délibérément
//  le vocabulaire ACP (`kind`, `status`, `ToolCallContent`) pour que le
//  décodage des `session/update` soit une transposition directe, sans couche
//  de traduction à maintenir.
//

import Foundation

// MARK: - Tour

/// Une entrée du fil. Chaque tour porte le glyphe qu'il affiche en gouttière.
enum Turn: Identifiable {
    case user(UserTurn)
    case assistant(AssistantTurn)
    case thought(ThoughtTurn)
    case toolCall(ToolCallTurn)
    case permission(PermissionTurn)
    case notice(NoticeTurn)

    var id: String {
        switch self {
        case .user(let t): "user-\(t.id)"
        case .assistant(let t): "assistant-\(t.id)"
        case .thought(let t): "thought-\(t.id)"
        case .toolCall(let t): "tool-\(t.id)"
        case .permission(let t): "perm-\(t.id)"
        case .notice(let t): "notice-\(t.id)"
        }
    }
}

/// Un fait du fil qui ne vient d'aucun des deux interlocuteurs : « interrompu »,
/// « quota atteint ». Ni une réponse, ni une commande — une note de marge.
///
/// Elle a sa propre variante plutôt que d'être glissée dans le texte de l'agent :
/// lui faire dire une chose qu'il n'a pas dite est un mensonge, et ce serait le
/// genre de mensonge qu'on relit six mois plus tard sans pouvoir le détecter.
struct NoticeTurn: Identifiable {
    let id: String
    var text: String
    var symbol: String = "minus.circle"
}

// MARK: - Variantes

struct UserTurn: Identifiable {
    let id: String
    var text: String
    /// Les images jointes, en JPEG déjà réduit.
    ///
    /// Elles ne survivent pas à une reprise du fil : `session/load` rejoue les
    /// demandes en texte, et le chemin de l'image sur le VPS y figure alors en
    /// toutes lettres. C'est un compromis assumé — renvoyer les pixels dans
    /// chaque rejeu d'historique coûterait plus cher que ce qu'il rapporte.
    var images: [Data] = []
}

/// Le texte de l'agent, tel qu'il arrive par `agent_message_chunk`.
///
/// Le texte est porté par un `MarkdownStream` plutôt que par une `String` :
/// c'est lui qui isole les blocs déjà figés de celui en cours d'écriture, et
/// donc ce qui empêche le rendu d'une longue réponse de devenir quadratique.
struct AssistantTurn: Identifiable {
    let id: String
    var stream: MarkdownStream
    var isStreaming: Bool = false

    init(id: String, markdown: String = "", isStreaming: Bool = false) {
        self.id = id
        self.stream = MarkdownStream(markdown)
        self.isStreaming = isStreaming
    }

    /// Le texte complet — pour la copie et les tests, jamais pour le rendu.
    var markdown: String { stream.text }

    mutating func append(_ chunk: String) { stream.append(chunk) }

    mutating func finish() {
        stream.finish()
        isStreaming = false
    }
}

/// Le raisonnement (`agent_thought_chunk`). Replié par défaut : c'est du
/// contexte, pas la réponse.
struct ThoughtTurn: Identifiable {
    let id: String
    var markdown: String
    var duration: Duration?
    var isStreaming: Bool = false
}

// MARK: - Appel d'outil

/// ACP : `read`, `edit`, `delete`, `move`, `search`, `execute`, `think`,
/// `fetch`, `other`.
nonisolated enum ToolKind: String, Codable, Sendable {
    case read, edit, delete, move, search, execute, think, fetch, other

    /// Le glyphe affiché à côté du titre. Les SF Symbols choisis restent dans
    /// le même registre graphique — trait fin, pas de remplissage.
    var symbol: String {
        switch self {
        case .read: "doc.text"
        case .edit: "pencil"
        case .delete: "trash"
        case .move: "arrow.right.doc.on.clipboard"
        case .search: "magnifyingglass"
        case .execute: "terminal"
        case .think: "brain"
        case .fetch: "arrow.down.circle"
        case .other: "wrench.adjustable"
        }
    }
}

/// ACP : `pending`, `in_progress`, `completed`, `failed`.
///
/// Les valeurs brutes sont celles du fil, en `snake_case` : c'est ce qui rend
/// le décodage direct, sans table de correspondance à maintenir.
nonisolated enum ToolStatus: String, Codable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
}

/// ACP : `ToolCallContent` ∈ { content, diff, terminal }.
enum ToolContent: Identifiable {
    case text(id: String, markdown: String)
    case diff(id: String, path: String, oldText: String?, newText: String)
    case terminal(id: String, output: String)

    var id: String {
        switch self {
        case .text(let id, _): id
        case .diff(let id, _, _, _): id
        case .terminal(let id, _): id
        }
    }
}

struct ToolCallTurn: Identifiable {
    /// L'identifiant ACP (`toolCallId`) : c'est lui qui permet à un
    /// `tool_call_update` de retrouver la ligne à modifier.
    let id: String
    var title: String
    var kind: ToolKind
    var status: ToolStatus
    /// Le fichier annoncé par ACP, quand il y en a un. Conservé séparément du
    /// titre : un titre est fait pour être lu, pas pour reconstruire une
    /// géographie fiable du dépôt.
    var location: String? = nil
    /// La ligne de droite : « 316 l · 0.4 s », « +18 −4 ». Toujours en
    /// monospace, toujours mesurée, jamais inventée.
    var detail: String?
    var content: [ToolContent] = []
    var isExpanded: Bool = false
}

// MARK: - Permission

/// Une option renvoyée par `session/request_permission`. Le libellé vient de
/// l'agent : il n'est jamais codé en dur côté app.
struct PermissionOption: Identifiable {
    /// ACP : `optionId`, à renvoyer tel quel dans l'`outcome`.
    let id: String
    var name: String
    /// ACP : `allow_once`, `allow_always`, `reject_once`, `reject_always`.
    var kind: Kind

    nonisolated enum Kind: String, Codable, Sendable {
        case allowOnce = "allow_once"
        case allowAlways = "allow_always"
        case rejectOnce = "reject_once"
        case rejectAlways = "reject_always"

        var isRejection: Bool { self == .rejectOnce || self == .rejectAlways }
    }
}

struct PermissionTurn: Identifiable {
    let id: String
    var toolTitle: String
    var kind: ToolKind
    /// Ce que l'agent s'apprête vraiment à faire — la commande, le chemin. Sans
    /// ça, autoriser est un acte aveugle.
    var detail: String
    var options: [PermissionOption]
    /// `nil` tant que la question est ouverte.
    var chosen: String?
    /// Renvoie le choix à l'agent. Tant qu'elle n'est pas appelée, le tour
    /// reste bloqué chez lui — c'est le seul effet de bord de cette carte.
    var respond: (@Sendable (String) async -> Void)?
}

// MARK: - Plan

/// ACP : la variante `plan` de `session/update`.
struct PlanEntry: Identifiable {
    let id: String
    var content: String
    var status: Status

    nonisolated enum Status: String, Codable, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
    }
}

// MARK: - Session

/// Le moteur qui répond. La bascule quota vit sur le VPS ; l'app ne fait
/// qu'afficher lequel des deux parle.
enum Engine: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var label: String { rawValue }
}
