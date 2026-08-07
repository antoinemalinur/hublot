//
//  ACPSchema.swift
//  Hublot
//
//  Le vocabulaire ACP. Chaque forme ici a été **relevée sur des trames réelles**
//  capturées au pont local (`Fixtures/*.jsonl`), pas recopiée de la
//  documentation — qui s'est révélée incomplète sur au moins deux points, notés
//  en commentaire là où ça compte.
//

import Foundation

// MARK: - Poignée de main

nonisolated struct InitializeParams: Encodable, Sendable {
    var protocolVersion = 1
    var clientCapabilities = ClientCapabilities()

    nonisolated struct ClientCapabilities: Encodable, Sendable {
        /// iOS est en bac à sable : l'app ne sert ni fichiers ni terminal. La
        /// logique qui en a besoin vit sur le VPS, c'est tout le principe.
        var fs = FileSystem()
        var terminal = false

        nonisolated struct FileSystem: Encodable, Sendable {
            var readTextFile = false
            var writeTextFile = false
        }
    }
}

nonisolated struct InitializeResult: Decodable, Sendable {
    var protocolVersion: Int
    var agentCapabilities: AgentCapabilities?
    var agentInfo: AgentInfo?
    var authMethods: [AuthMethod]?

    nonisolated struct AgentCapabilities: Decodable, Sendable {
        var loadSession: Bool?
        var promptCapabilities: PromptCapabilities?
        /// Mesuré : l'agent annonce ses méthodes de session par *présence de
        /// clé*, pas par booléen — `{"list": {}, "resume": {}}`. D'où le
        /// dictionnaire plutôt qu'une structure de drapeaux.
        var sessionCapabilities: [String: JSONValue]?

        var supportsListing: Bool { sessionCapabilities?["list"] != nil }
        var supportsResume: Bool { sessionCapabilities?["resume"] != nil }
        var supportsLoad: Bool { loadSession == true }
    }

    nonisolated struct PromptCapabilities: Decodable, Sendable {
        var image: Bool?
        var embeddedContext: Bool?
    }

    nonisolated struct AgentInfo: Decodable, Sendable {
        var name: String?
        var title: String?
        var version: String?
    }

    nonisolated struct AuthMethod: Decodable, Sendable {
        var id: String?
        var name: String?
    }
}

// MARK: - Sessions

nonisolated struct NewSessionParams: Encodable, Sendable {
    /// Obligatoire, mesuré : l'agent refuse `session/new` sans répertoire de
    /// travail. Côté VPS c'est le dépôt qu'on pilote.
    var cwd: String
    var mcpServers: [JSONValue] = []
}

nonisolated struct SessionRef: Decodable, Sendable {
    var sessionId: String
}

/// Ce que renvoient `session/new` et `session/load` — relevé sur l'iPhone
/// d'Antoine le 6 août 2026.
///
/// **Correction d'une erreur** : `session/list_config_options` n'existe pas, et
/// j'en avais conclu que le client ne pouvait pas découvrir les réglages. Faux.
/// Ils arrivent *avec la session*, entièrement décrits — et
/// `session/set_config_option` renvoie la liste mise à jour. Les pilules n'ont
/// donc rien à inventer.
nonisolated struct SessionSetup: Decodable, Sendable {
    var sessionId: String?
    var configOptions: [ConfigOption]?
}

nonisolated struct ConfigOption: Decodable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String
    var description: String?
    /// `model`, `thought_level`, `mode`… absent sur certains réglages.
    var category: String?
    var type: String
    var currentValue: JSONValue?
    var options: [Choice]?

    nonisolated struct Choice: Decodable, Sendable, Hashable, Identifiable {
        var value: String
        var name: String
        var description: String?
        var id: String { value }
    }

    var currentValueString: String? { currentValue?.stringValue }

    /// Le libellé lisible de la valeur courante — « Opus », pas
    /// « claude-opus-5 ». Repli sur la valeur brute si l'agent ne nomme pas.
    var currentLabel: String {
        guard let current = currentValueString else { return name }
        return options?.first { $0.value == current }?.name ?? current
    }
}

/// L'écriture d'un réglage. Le `type` est celui que l'agent a déclaré dans le
/// descripteur — on ne le devine pas.
nonisolated struct SetConfigOptionParams: Encodable, Sendable {
    var sessionId: String
    var configId: String
    var type: String
    var value: String
}

/// La réponse à `session/set_config_option` : la liste complète, à jour.
nonisolated struct ConfigOptionsResult: Decodable, Sendable {
    var configOptions: [ConfigOption]?
}

/// Réponse de `hublot/projects` : un vrai `ls` de `/root/repos`, relu à chaque
/// appel côté serveur. Un dépôt cloné il y a trente secondes est là.
nonisolated struct ProjectListResult: Decodable, Sendable {
    var projects: [Project]

    nonisolated struct Project: Decodable, Sendable, Identifiable, Hashable {
        var name: String
        var path: String
        var sessionCount: Int
        var updatedAt: Date?

        var id: String { path }
    }
}

/// Le fichier d'instructions d'un dépôt — `CLAUDE.md` et ses variantes.
/// Claude le lit au démarrage de chaque session : le consulter depuis le
/// téléphone évite de deviner pourquoi l'agent se comporte d'une certaine façon.
nonisolated struct InstructionsResult: Decodable, Sendable {
    var instructions: Document?

    nonisolated struct Document: Decodable, Sendable, Hashable {
        var path: String
        var content: String
        var bytes: Int?
        var updatedAt: Date?

        /// « 4,2 ko » — l'ordre de grandeur suffit à savoir si on ouvre un
        /// mémo ou un règlement.
        var size: String {
            guard let bytes else { return "" }
            return bytes < 1024
                ? "\(bytes) o"
                : String(format: "%.1f ko", Double(bytes) / 1024)
        }
    }
}

nonisolated struct ListSessionsParams: Encodable, Sendable {
    var cwd: String
}

nonisolated struct DeleteSessionParams: Encodable, Sendable {
    var sessionId: String
    var cwd: String
}

/// Réponse de `session/list`, relevée au pont :
/// `{"sessions": [{"sessionId", "cwd", "title", "updatedAt"}]}`.
nonisolated struct SessionListResult: Decodable, Sendable {
    var sessions: [Summary]

    nonisolated struct Summary: Decodable, Sendable, Identifiable, Hashable {
        var sessionId: String
        var cwd: String?
        var title: String?
        var updatedAt: Date?
        /// Le nombre de questions posées : ce qui distingue une conversation
        /// nourrie d'un fil ouvert puis abandonné.
        var exchanges: Int?

        var id: String { sessionId }

        /// Le titre que l'agent donne est souvent la première question, en
        /// entier. On la coupe pour qu'elle tienne sur une ligne de liste.
        var displayTitle: String {
            let raw = (title?.isEmpty == false ? title! : "Session sans titre")
                .replacingOccurrences(of: "\n", with: " ")
            return raw.count > 70 ? String(raw.prefix(69)) + "…" : raw
        }
    }
}

/// Mesuré : `session/resume` exige `cwd` en plus de l'identifiant — la
/// documentation ne le mentionne pas, et l'omettre renvoie `-32602`.
nonisolated struct ResumeSessionParams: Encodable, Sendable {
    var sessionId: String
    var cwd: String
}

nonisolated struct LoadSessionParams: Encodable, Sendable {
    var sessionId: String
    var cwd: String
    var mcpServers: [JSONValue] = []
}

// MARK: - Tour de conversation

nonisolated struct PromptParams: Encodable, Sendable {
    var sessionId: String
    var prompt: [ContentBlock]
}

nonisolated struct PromptResult: Decodable, Sendable {
    var stopReason: StopReason
}

nonisolated enum StopReason: String, Codable, Sendable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
    case cancelled
}

nonisolated struct CancelParams: Encodable, Sendable {
    var sessionId: String
}

// MARK: - Réglages de session

nonisolated struct SetModeParams: Encodable, Sendable {
    var sessionId: String
    var modeId: String
}

// MARK: - Blocs de contenu

nonisolated enum ContentBlock: Codable, Sendable, Hashable {
    case text(String)
    /// Tout ce qui n'est pas du texte : image, lien de ressource, ressource
    /// embarquée. Conservé brut plutôt qu'ignoré — hors périmètre v1, mais on
    /// ne perd pas la donnée.
    case other(JSONValue)

    private enum CodingKeys: String, CodingKey { case type, text }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decodeIfPresent(String.self, forKey: .type) == "text" {
            self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")
        } else {
            self = .other(try JSONValue(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let text):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .other(let value):
            try value.encode(to: encoder)
        }
    }

    var text: String? {
        guard case .text(let value) = self else { return nil }
        return value
    }
}

// MARK: - Notifications de session

nonisolated struct SessionNotification: Decodable, Sendable {
    var sessionId: String
    var update: SessionUpdate
}

nonisolated enum SessionUpdate: Decodable, Sendable {
    /// Émis par `session/load` en rejouant l'historique : ce que *l'utilisateur*
    /// avait écrit. Absent d'une session neuve, d'où son oubli initial — sans
    /// lui, reprendre une session affichait un fil amputé de ses questions.
    case userMessageChunk(messageId: String?, content: ContentBlock)
    case agentMessageChunk(messageId: String?, content: ContentBlock)
    case agentThoughtChunk(messageId: String?, content: ContentBlock)
    case toolCall(ToolCallPayload)
    case toolCallUpdate(ToolCallPayload)
    case plan([PlanEntryPayload])
    case availableCommands([AvailableCommand])
    case currentMode(String)
    case usage(used: Int, size: Int, status: SessionStatus?)
    /// Une variante qu'on ne connaît pas encore.
    ///
    /// Le protocole bouge ; une variante inconnue doit être ignorée, jamais
    /// faire tomber le flux. C'est la différence entre « une nouveauté ne
    /// s'affiche pas » et « la conversation se coupe ».
    case unrecognised(String)

    private enum CodingKeys: String, CodingKey {
        case sessionUpdate, content, messageId, entries, availableCommands
        case currentModeId, used, size
        case meta = "_meta"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .sessionUpdate)

        switch kind {
        case "user_message_chunk":
            self = .userMessageChunk(
                messageId: try container.decodeIfPresent(String.self, forKey: .messageId),
                content: try container.decode(ContentBlock.self, forKey: .content)
            )
        case "agent_message_chunk":
            self = .agentMessageChunk(
                messageId: try container.decodeIfPresent(String.self, forKey: .messageId),
                content: try container.decode(ContentBlock.self, forKey: .content)
            )
        case "agent_thought_chunk":
            self = .agentThoughtChunk(
                messageId: try container.decodeIfPresent(String.self, forKey: .messageId),
                content: try container.decode(ContentBlock.self, forKey: .content)
            )
        case "tool_call":
            self = .toolCall(try ToolCallPayload(from: decoder))
        case "tool_call_update":
            self = .toolCallUpdate(try ToolCallPayload(from: decoder))
        case "plan":
            self = .plan(try container.decodeIfPresent([PlanEntryPayload].self, forKey: .entries) ?? [])
        case "available_commands_update":
            self = .availableCommands(
                try container.decodeIfPresent([AvailableCommand].self, forKey: .availableCommands) ?? []
            )
        case "current_mode_update":
            self = .currentMode(try container.decodeIfPresent(String.self, forKey: .currentModeId) ?? "")
        case "usage_update":
            let meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
            self = .usage(
                used: try container.decodeIfPresent(Int.self, forKey: .used) ?? 0,
                size: try container.decodeIfPresent(Int.self, forKey: .size) ?? 0,
                status: try meta?["hublot"]?.decode(SessionStatus.self)
            )
        default:
            self = .unrecognised(kind)
        }
    }
}

// MARK: - Appels d'outils

/// La charge de `tool_call` **et** de `tool_call_update`.
///
/// Mesuré, contre la documentation : un `tool_call_update` transporte aussi
/// `title`, `kind` et `locations`, pas seulement le statut. En pratique le
/// premier `tool_call` arrive avec un titre générique (« Read File ») et c'est
/// la mise à jour qui donne le vrai (« Read Tools/acp-probe.mjs »). Tout champ
/// absent doit donc laisser la valeur précédente en place, jamais l'écraser.
nonisolated struct ToolCallPayload: Decodable, Sendable {
    var toolCallId: String
    var title: String?
    var kind: ToolKind?
    var status: ToolStatus?
    var content: [ToolCallContent]?
    var locations: [ToolLocation]?
    var rawInput: JSONValue?
    var rawOutput: JSONValue?
    /// `_meta.claudeCode.toolName` : le vrai nom de l'outil (« Read », « Bash »),
    /// plus parlant que le titre générique.
    var toolName: String?

    private enum CodingKeys: String, CodingKey {
        case toolCallId, title, kind, status, content, locations, rawInput, rawOutput
        case meta = "_meta"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try container.decode(String.self, forKey: .toolCallId)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        kind = try container.decodeIfPresent(ToolKind.self, forKey: .kind)
        status = try container.decodeIfPresent(ToolStatus.self, forKey: .status)
        content = try container.decodeIfPresent([ToolCallContent].self, forKey: .content)
        locations = try container.decodeIfPresent([ToolLocation].self, forKey: .locations)
        rawInput = try container.decodeIfPresent(JSONValue.self, forKey: .rawInput)
        rawOutput = try container.decodeIfPresent(JSONValue.self, forKey: .rawOutput)
        toolName = try container
            .decodeIfPresent(JSONValue.self, forKey: .meta)?["claudeCode"]?["toolName"]?.stringValue
    }
}

nonisolated struct ToolLocation: Decodable, Sendable, Hashable {
    var path: String
    var line: Int?
}

nonisolated enum ToolCallContent: Decodable, Sendable {
    case content(ContentBlock)
    case diff(path: String, oldText: String?, newText: String)
    case terminal(terminalId: String)
    case unrecognised(String)

    private enum CodingKeys: String, CodingKey {
        case type, content, path, oldText, newText, terminalId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "content":
            self = .content(try container.decode(ContentBlock.self, forKey: .content))
        case "diff":
            self = .diff(
                path: try container.decode(String.self, forKey: .path),
                oldText: try container.decodeIfPresent(String.self, forKey: .oldText),
                newText: try container.decodeIfPresent(String.self, forKey: .newText) ?? ""
            )
        case "terminal":
            self = .terminal(terminalId: try container.decode(String.self, forKey: .terminalId))
        case let other:
            self = .unrecognised(other)
        }
    }
}

// MARK: - Plan et commandes

nonisolated struct PlanEntryPayload: Decodable, Sendable {
    var content: String
    var status: PlanEntry.Status
    var priority: String?
}

/// L'état que le serveur pousse avec la consommation de contexte : modèle,
/// effort, moteur et plafonds. Les mêmes chiffres que la barre de statut du
/// terminal, calculés par le moniteur du VPS et jamais ici.
nonisolated struct SessionStatus: Decodable, Sendable, Hashable {
    var model: String?
    var effort: String?
    var engine: String?
    var limits: [String: Window]?

    nonisolated struct Window: Decodable, Sendable, Hashable {
        var percent: Int
        var resetsAt: Date?

        /// « 4:59 » — le temps qu'il reste, pas l'heure absolue : c'est la
        /// question qu'on se pose devant un plafond.
        var remaining: String? {
            guard let resetsAt else { return nil }
            let seconds = max(0, Int(resetsAt.timeIntervalSinceNow))
            return String(format: "%d:%02d", seconds / 3600, (seconds % 3600) / 60)
        }
    }

    var fiveHour: Window? { limits?["five_hour"] }
    var weekly: Window? { limits?["seven_day"] }
}

/// `hublot/transcribe` : l'audio monte en base64, le texte redescend.
///
/// Le son voyage dans la trame JSON-RPC plutôt que par un envoi séparé — une
/// dictée de trois minutes en AAC 16 kHz pèse moins de 400 ko, et une seconde
/// liaison à authentifier pour ça ne se justifie pas.
nonisolated struct TranscribeParams: Encodable, Sendable {
    var audio: String
    var filename = "dictee.m4a"
    var language = "fr"
}

nonisolated struct TranscribeResult: Decodable, Sendable {
    var text: String
}

nonisolated struct AvailableCommand: Decodable, Sendable, Hashable {
    var name: String
    var description: String?
}

// MARK: - Permissions

nonisolated struct PermissionRequest: Decodable, Sendable {
    var sessionId: String
    var toolCall: ToolCallPayload
    var options: [Option]

    nonisolated struct Option: Decodable, Sendable {
        var optionId: String
        var name: String
        var kind: PermissionOption.Kind
    }
}

/// La réponse attendue : `{"outcome": {"outcome": "selected", "optionId": "…"}}`.
/// L'imbrication est celle du protocole, pas une maladresse.
nonisolated struct PermissionResponse: Encodable, Sendable {
    var outcome: Outcome

    nonisolated struct Outcome: Encodable, Sendable {
        var outcome: String
        var optionId: String?
    }

    static func selected(_ optionId: String) -> Self {
        .init(outcome: .init(outcome: "selected", optionId: optionId))
    }

    static let cancelled = Self(outcome: .init(outcome: "cancelled", optionId: nil))
}
