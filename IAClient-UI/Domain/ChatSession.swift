//
//  ChatSession.swift
//  Hublot
//
//  Le seul endroit qui traduit le protocole en fil de conversation. Tout ce qui
//  est ici tourne sur le `MainActor` ; tout ce qui est dans `ACP/` n'en sait
//  rien. La frontière est ce qui permettra de brancher le serveur du VPS sans
//  toucher à l'interface.
//

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class ChatSession {

    enum Status: Equatable {
        case idle
        case connecting
        case ready
        case failed(String)
    }

    private(set) var turns: [Turn] = []
    private(set) var plan: [PlanEntry] = []
    private(set) var status: Status = .idle
    private(set) var title = "Nouvelle session"
    private(set) var engine: Engine = .claude
    /// Contexte consommé, tel qu'annoncé par `usage_update`. Mesuré par
    /// l'agent, jamais estimé ici.
    private(set) var contextUsed = 0
    private(set) var contextSize = 0
    /// Modèle, effort, moteur et plafonds, poussés par le serveur. Distinct de
    /// `status`, qui décrit l'état de la liaison.
    private(set) var metrics: SessionStatus?
    /// Les commandes que le moteur courant accepte. Vide pour Codex, qui n'en
    /// expose aucune en mode `exec` — ce sont des sous-commandes du CLI, pas
    /// des commandes de conversation.
    private(set) var commands: [String] = []

    /// Le pourcentage de fenêtre de contexte consommé, ou `nil` avant le
    /// premier échange : afficher 0 % laisserait croire à une mesure.
    var contextPercent: Int? {
        guard contextSize > 0, contextUsed > 0 else { return nil }
        return Int((Double(contextUsed) / Double(contextSize)) * 100)
    }

    var machine: MachineState { .derive(from: turns) }

    /// Vrai tant que l'agent a la main. L'interface s'en sert pour remplacer le
    /// bouton d'envoi par un bouton d'arrêt — sans ça, un tour parti pour dix
    /// minutes ne se rattrape plus.
    var isWorking: Bool { isPrompting }

    private let connection: ACPConnection
    private let events: AsyncStream<ACPConnection.Event>
    private let workingDirectory: String
    private var sessionId: String?
    private var capabilities: InitializeResult.AgentCapabilities?
    private var pump: Task<Void, Never>?

    /// Où vit chaque `messageId` dans le fil. Sans cette table, deux réponses
    /// successives fusionneraient en une seule.
    ///
    /// Elle n'est **jamais vidée**, et c'est délibéré. Elle l'était à la fin de
    /// chaque tour, ce qui ouvrait une fenêtre courte mais réelle : la réponse à
    /// `session/prompt` et les derniers morceaux de texte arrivent dans la même
    /// lecture du socket, et la réponse est traitée la première. Les morceaux
    /// retardataires ne retrouvaient alors plus leur tour et en ouvraient un
    /// second — **avec le même identifiant**. Deux entrées de même identité dans
    /// un `ForEach`, et SwiftUI cesse d'afficher la suite.
    private var messageIndex: [String: Int] = [:]
    private var thoughtIndex: [String: Int] = [:]
    private var toolIndex: [String: Int] = [:]
    /// Vrai tant qu'on rejoue un historique — donc jusqu'au premier envoi.
    private var isReplaying = false
    /// Vrai entre l'envoi et le `stopReason`. C'est ce qui distingue un morceau
    /// en cours d'écriture — curseur qui bat — d'un morceau arrivé après coup.
    private var isPrompting = false
    /// L'envoi suspendu en attente de son jalon de fin de tour.
    private var settlement: CheckedContinuation<Void, Never>?

    private let log = Logger(subsystem: "hublot", category: "session")

    /// Une session déjà ouverte par `AppModel` : la poignée de main et le choix
    /// de la session lui appartiennent, pas au fil de conversation.
    /// L'abonnement est fourni par l'appelant, déjà ouvert.
    ///
    /// Le prendre ici serait trop tard : `session/load` rejoue l'historique par
    /// notifications **avant** de répondre, et un abonnement pris après coup ne
    /// verrait rien de ce passé.
    init(
        connection: ACPConnection, events: AsyncStream<ACPConnection.Event>,
        workingDirectory: String, sessionId: String,
        title: String, isResuming: Bool = false, status: SessionStatus? = nil
    ) {
        // Déterminé par l'appelant, pas déduit de l'ordre d'arrivée : une
        // conversation qui commence par une réponse — cela arrive — laissait
        // tous les messages rejoués marqués « en cours d'écriture », curseur
        // clignotant compris.
        self.connection = connection
        self.events = events
        self.workingDirectory = workingDirectory
        self.sessionId = sessionId
        self.title = title
        self.status = .ready
        self.isReplaying = isResuming
        // Les plafonds sont ceux de la machine, pas d'une conversation : les
        // reprendre d'emblée évite une barre vide jusqu'au premier tour.
        self.metrics = status
        if let name = status?.engine, let known = Engine(rawValue: name) { self.engine = known }
        self.pump = Task { [weak self] in await self?.consumeEvents() }
    }

    // MARK: Cycle de vie

    func start() async throws {
        try await connection.start()
    }

    /// Ferme le fil, pas la liaison : la connexion appartient à `AppModel` et
    /// sert aussi à lister les sessions. La couper ici obligerait à refaire une
    /// poignée de main à chaque aller-retour vers la liste.
    func disconnect() async {
        pump?.cancel()
        pump = nil
        status = .idle
        release()
    }

    // MARK: Envoi

    /// Envoie une demande, avec ou sans images.
    ///
    /// Les images passent **avant** le texte dans la liste de blocs : c'est
    /// l'ordre que recommande Anthropic pour la vision, et celui qui donne les
    /// réponses les plus fidèles quand la question porte sur ce qu'on montre.
    func send(_ text: String, attachments: [Attachment] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Une image seule est une demande valable : « regarde ça ». Ce qu'elle
        // veut dire, le serveur l'écrira à côté du chemin du fichier.
        guard !trimmed.isEmpty || !attachments.isEmpty, let sessionId else { return }

        isReplaying = false
        isPrompting = true
        turns.append(
            .user(
                .init(
                    id: UUID().uuidString, text: trimmed,
                    images: attachments.map(\.jpeg)
                )
            )
        )
        // Le titre reste celui du projet : c'est lui qu'on pilote, et le
        // remplacer par la première question faisait perdre de vue où l'on
        // travaille dès le premier message.

        do {
            let blocks = attachments.map(\.block) + (trimmed.isEmpty ? [] : [.text(trimmed)])
            let result = try await connection.call(
                "session/prompt",
                PromptParams(sessionId: sessionId, prompt: blocks),
                as: PromptResult.self,
                timeout: nil
            )
            // On attend que la file soit vidée avant de conclure : sans ça
            // l'aperçu de la notification partait vide, et le curseur s'éteignait
            // sur une réponse encore en train de s'écrire à l'écran.
            await settle(reason: result.stopReason)
            Notifier.turnFinished(session: title, preview: lastAssistantText)
        } catch {
            finishStreaming(reason: nil)
            status = .failed(error.localizedDescription)
        }
    }

    /// Rend la main quand tout ce qui précédait le `stopReason` a été posé dans
    /// le fil. Le jalon voyage par la file d'événements, donc derrière chaque
    /// morceau déjà diffusé.
    private func settle(reason: StopReason?) async {
        guard let sessionId, pump != nil else {
            finishStreaming(reason: reason)
            return
        }
        await withCheckedContinuation { continuation in
            settlement = continuation
            Task { await connection.finishTurn(session: sessionId, reason: reason) }
            // Un garde-fou, pas un délai de fonctionnement : le jalon arrive en
            // quelques microsecondes. S'il se perdait, l'envoi resterait suspendu
            // pour toujours et le curseur battrait sur un tour déjà fini — mieux
            // vaut conclure en retard que jamais.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.settlement != nil else { return }
                self.log.error("jalon de fin de tour perdu")
                self.finishStreaming(reason: reason)
                self.release()
            }
        }
    }

    /// Libère l'envoi en cours. Appelée par le jalon, et par toute sortie de la
    /// boucle — une liaison coupée ne doit pas laisser `send` suspendu.
    private func release() {
        settlement?.resume()
        settlement = nil
    }

    /// Transcrit une dictée. Le texte revient à l'appelant, qui le pose dans la
    /// zone de saisie — jamais directement dans le fil.
    func transcribe(_ audio: Data) async throws -> String {
        try await connection.call(
            "hublot/transcribe",
            TranscribeParams(audio: audio.base64EncodedString()),
            as: TranscribeResult.self,
            timeout: .seconds(120)
        ).text
    }

    func cancel() async {
        guard let sessionId, isPrompting else { return }
        try? await connection.notify("session/cancel", CancelParams(sessionId: sessionId))
    }

    private static func shorten(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 60 ? String(flat.prefix(59)) + "…" : flat
    }

    // MARK: Réglages

    /// Les réglages tels que l'agent les décrit : identifiants, libellés,
    /// valeurs possibles et valeur courante. Rien n'est inventé côté app —
    /// ils arrivent avec la session et repartent à jour après chaque écriture.
    private(set) var configOptions: [ConfigOption] = []

    /// Le dernier refus de l'agent, pour que l'interface puisse le dire au lieu
    /// de faire semblant que le réglage a pris.
    private(set) var settingRejected: String?

    func apply(_ setup: SessionSetup?) {
        guard let options = setup?.configOptions else { return }
        configOptions = options
    }

    /// Écrit un réglage et adopte la liste que l'agent renvoie. En cas de refus
    /// on ne touche à rien : l'interface ne doit jamais montrer un état qu'elle
    /// n'a pas obtenu.
    func choose(_ option: ConfigOption, value: String) async {
        guard let sessionId, option.currentValueString != value else { return }
        do {
            let result = try await connection.call(
                "session/set_config_option",
                SetConfigOptionParams(
                    sessionId: sessionId, configId: option.id, type: option.type, value: value
                ),
                as: ConfigOptionsResult.self
            )
            if let updated = result.configOptions { configOptions = updated }
            settingRejected = nil
        } catch {
            settingRejected = "« \(option.name) » refusé : \(error.localizedDescription)"
            log.notice("set_config_option \(option.id, privacy: .public) refusé")
        }
    }

    // MARK: Réception

    private func consumeEvents() async {
        for await event in events {
            guard !Task.isCancelled else { return }
            switch event {
            case .update(let notification):
                // Une même liaison sert plusieurs sessions : sans ce filtre,
                // l'historique rejoué d'une session atterrirait dans une autre.
                guard notification.sessionId == sessionId else { continue }
                apply(notification.update)
            case .permission(let request, let respond):
                present(request, respond: respond)
            case .turnFinished(let id, let reason):
                guard id == sessionId else { continue }
                finishStreaming(reason: reason)
                release()

            case .disconnected(let error):
                status = error.map { .failed($0.localizedDescription) } ?? .idle
                release()
            }
        }
        // La boucle ne s'arrête que si la liaison tombe ou si le fil se ferme :
        // dans les deux cas, personne ne doit rester en attente.
        release()
    }

    private func apply(_ update: SessionUpdate) {
        switch update {
        case .userMessageChunk(_, let content):
            guard let text = content.text, !text.isEmpty else { return }
            turns.append(.user(.init(id: UUID().uuidString, text: text)))
            if turns.count == 1 { title = Self.shorten(text) }

        case .agentMessageChunk(let messageId, let content):
            guard let text = content.text else { return }
            appendMessage(text, messageId: messageId ?? "unique")

        case .agentThoughtChunk(let messageId, let content):
            guard let text = content.text else { return }
            appendThought(text, messageId: messageId ?? "unique")

        case .toolCall(let payload):
            upsertTool(payload)

        case .toolCallUpdate(let payload):
            upsertTool(payload)

        case .plan(let entries):
            plan = entries.enumerated().map { index, entry in
                PlanEntry(id: "plan-\(index)", content: entry.content, status: entry.status)
            }

        case .usage(let used, let size, let pushed):
            contextUsed = used
            contextSize = size
            if let pushed { adopt(pushed) }

        case .availableCommands(let list):
            // Annoncées par le moteur, jamais écrites en dur : un plugin
            // installé sur le VPS apparaît dans la palette sans toucher à l'app.
            commands = list.map(\.name).sorted()

        case .currentMode:
            break

        case .unrecognised(let kind):
            log.notice("variante de session/update ignorée : \(kind, privacy: .public)")
        }
    }

    // MARK: Fusion dans le fil

    /// Adopte l'état poussé par le serveur — plafonds, modèle, et **moteur**.
    ///
    /// `engine` était fixé à `.claude` à la construction et plus jamais touché :
    /// choisir Codex changeait bien de moteur sur le VPS, mais la pastille à
    /// côté du nom du dépôt continuait d'annoncer Claude. Elle affirmait une
    /// chose que l'app n'avait jamais vérifiée.
    private func adopt(_ status: SessionStatus) {
        metrics = status
        // `auto` n'est pas un moteur : le serveur envoie celui qu'il a résolu.
        if let name = status.engine, let known = Engine(rawValue: name) { engine = known }
    }

    private func appendMessage(_ text: String, messageId: String) {
        if let index = messageIndex[messageId], case .assistant(var turn) = turns[index] {
            turn.append(text)
            turns[index] = .assistant(turn)
            return
        }
        // Un message rejoué est déjà écrit : le marquer « en cours » faisait
        // clignoter le curseur et respirer la lueur pour du texte figé, comme
        // si la machine travaillait alors qu'elle ne fait rien.
        var turn = AssistantTurn(id: messageId, isStreaming: isPrompting && !isReplaying)
        turn.append(text)
        turns.append(.assistant(turn))
        messageIndex[messageId] = turns.count - 1
    }

    private func appendThought(_ text: String, messageId: String) {
        if let index = thoughtIndex[messageId], case .thought(var turn) = turns[index] {
            turn.markdown += text
            turns[index] = .thought(turn)
            return
        }
        turns.append(
            .thought(.init(id: messageId, markdown: text, isStreaming: isPrompting))
        )
        thoughtIndex[messageId] = turns.count - 1
    }

    /// Fusionne une charge d'outil dans le fil.
    ///
    /// Le point délicat, mesuré sur trames réelles : un `tool_call_update`
    /// n'envoie que ce qui change. Tout champ absent doit **laisser la valeur
    /// précédente** — écraser avec `nil` ferait disparaître le titre exact que
    /// la mise à jour venait justement d'apporter.
    private func upsertTool(_ payload: ToolCallPayload) {
        let content = payload.content?.compactMap(Self.convert) ?? []

        if let index = toolIndex[payload.toolCallId], case .toolCall(var turn) = turns[index] {
            if let title = payload.title { turn.title = Self.title(payload) ?? title }
            if let kind = payload.kind { turn.kind = kind }
            if let status = payload.status { turn.status = status }
            if let location = Self.location(payload) { turn.location = location }
            if !content.isEmpty { turn.content = content }
            if let detail = Self.detail(payload) { turn.detail = detail }
            turns[index] = .toolCall(turn)
            return
        }

        turns.append(
            .toolCall(
                .init(
                    id: payload.toolCallId,
                    title: Self.title(payload) ?? payload.title ?? "outil",
                    kind: payload.kind ?? .other,
                    status: payload.status ?? .pending,
                    location: Self.location(payload),
                    detail: Self.detail(payload),
                    content: content
                )
            )
        )
        toolIndex[payload.toolCallId] = turns.count - 1
    }

    /// Le titre affiché. `_meta.claudeCode.toolName` donne « Read » quand le
    /// titre du protocole dit encore « Read File » ; on préfère le chemin réel
    /// dès qu'il arrive.
    private static func title(_ payload: ToolCallPayload) -> String? {
        if let path = payload.locations?.first?.path {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        if let command = payload.rawInput?["command"]?.stringValue { return command }
        return payload.title
    }

    /// L'emplacement factuel de l'appel. Certaines implémentations ACP
    /// remplissent `locations`, d'autres ne donnent que l'entrée brute.
    private static func location(_ payload: ToolCallPayload) -> String? {
        if let path = payload.locations?.first?.path, !path.isEmpty { return path }
        for key in ["file_path", "path"] {
            if let path = payload.rawInput?[key]?.stringValue, !path.isEmpty { return path }
        }
        return nil
    }

    private static func detail(_ payload: ToolCallPayload) -> String? {
        payload.status == .failed ? "échec" : nil
    }

    private static func convert(_ content: ToolCallContent) -> ToolContent? {
        switch content {
        case .content(let block):
            block.text.map { .text(id: UUID().uuidString, markdown: $0) }
        case .diff(let path, let oldText, let newText):
            .diff(id: UUID().uuidString, path: path, oldText: oldText, newText: newText)
        case .terminal(let terminalId):
            .terminal(id: terminalId, output: "")
        case .unrecognised:
            nil
        }
    }

    private func finishStreaming(reason: StopReason?) {
        for index in turns.indices {
            if case .assistant(var turn) = turns[index], turn.isStreaming {
                turn.finish()
                turns[index] = .assistant(turn)
            }
            if case .thought(var turn) = turns[index], turn.isStreaming {
                turn.isStreaming = false
                turns[index] = .thought(turn)
            }
        }
        isPrompting = false
        if let reason, reason != .endTurn {
            log.notice("tour terminé sur \(reason.rawValue, privacy: .public)")
            if let note = Self.note(for: reason) {
                turns.append(.notice(.init(id: UUID().uuidString, text: note.0, symbol: note.1)))
            }
        }
    }

    /// Ce qu'on écrit dans le fil quand un tour ne s'est pas terminé de
    /// lui-même. `end_turn` ne dit rien : c'est le cas normal.
    private static func note(for reason: StopReason) -> (String, String)? {
        switch reason {
        case .endTurn: nil
        case .cancelled: ("interrompu", "stop.circle")
        case .refusal: ("refusé par le moteur", "exclamationmark.circle")
        case .maxTokens: ("coupé : réponse trop longue", "scissors")
        case .maxTurnRequests: ("coupé : trop d'allers-retours", "scissors")
        }
    }

    // MARK: Permissions

    private func present(
        _ request: PermissionRequest,
        respond: @escaping @Sendable (PermissionResponse) async -> Void
    ) {
        let turn = PermissionTurn(
            id: request.toolCall.toolCallId,
            toolTitle: request.toolCall.toolName ?? request.toolCall.title ?? "outil",
            kind: request.toolCall.kind ?? .other,
            detail: Self.commandLine(request.toolCall),
            options: request.options.map {
                PermissionOption(id: $0.optionId, name: $0.name, kind: $0.kind)
            },
            chosen: nil,
            respond: { optionId in
                await respond(.selected(optionId))
            }
        )
        turns.append(.permission(turn))
        Notifier.permissionNeeded(tool: turn.toolTitle, detail: turn.detail)
    }

    /// Le début de la dernière réponse, pour le corps de la notification.
    private var lastAssistantText: String {
        for turn in turns.reversed() {
            if case .assistant(let assistant) = turn { return assistant.markdown }
        }
        return ""
    }

    /// Ce que l'agent s'apprête vraiment à faire. Sans ça, autoriser est un
    /// acte aveugle — donc on ne se contente jamais du titre.
    private static func commandLine(_ call: ToolCallPayload) -> String {
        if let command = call.rawInput?["command"]?.stringValue { return command }
        if let path = call.rawInput?["file_path"]?.stringValue { return path }
        if let locations = call.locations, let first = locations.first { return first.path }
        return call.title ?? "—"
    }
}
