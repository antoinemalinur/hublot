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
    /// Toutes les mesures reçues, dans l'ordre. C'est la matière de la marée
    /// de contexte.
    ///
    /// On retient **tout**, y compris ce qui ne se trace pas : c'est
    /// `ContextTide` qui décide de ce qu'il sait dessiner. Un enregistreur qui
    /// filtre à l'entrée perd la trace de ce qu'il a jeté, et le fil n'a alors
    /// plus aucun moyen de dire qu'une mesure est arrivée incohérente.
    ///
    /// Le rejeu de `session/load` la remplit comme le direct : `apply` ne
    /// distingue pas les deux, exactement comme pour `turns` et `plan`.
    private(set) var contextHistory: [ContextTide.Sample] = []
    /// Modèle, effort, moteur et plafonds, poussés par le serveur. Distinct de
    /// `status`, qui décrit l'état de la liaison.
    private(set) var metrics: SessionStatus?
    /// Les commandes que le moteur courant accepte. Vide pour Codex, qui n'en
    /// expose aucune en mode `exec` — ce sont des sous-commandes du CLI, pas
    /// des commandes de conversation.
    private(set) var commands: [String] = []

    /// Le pourcentage de fenêtre de contexte consommé, ou `nil` avant le
    /// premier échange : afficher 0 % laisserait croire à une mesure.
    ///
    /// Au-delà de cent, la barre se tait. Une fenêtre ne peut pas être remplie
    /// à 1540 % — ce chiffre-là a réellement été affiché, le serveur envoyant
    /// le total des jetons d'un tour au lieu du contexte porté. Devant un
    /// plafond, une case vide dit « je ne sais pas » ; un nombre impossible,
    /// lui, discrédite tout le reste de la barre.
    var contextPercent: Int? {
        guard contextSize > 0, contextUsed > 0 else { return nil }
        let percent = Int((Double(contextUsed) / Double(contextSize)) * 100)
        guard percent <= 100 else {
            log.error("contexte incohérent : \(self.contextUsed)/\(self.contextSize)")
            return nil
        }
        return percent
    }

    /// Le dernier signe de vie du relais, et l'heure de sa réception.
    ///
    /// Les deux comptent. Ce que le serveur dit — quelle phase, quel silence —
    /// et le fait qu'il le dise encore : un battement qui cesse est lui-même une
    /// information, celle d'une liaison qui ne porte plus rien.
    private(set) var activity: Activity?
    private(set) var activityAt: Date?

    var machine: MachineState { .derive(from: turns) }

    /// Vrai tant que l'agent a la main. L'interface s'en sert pour remplacer le
    /// bouton d'envoi par un bouton d'arrêt — sans ça, un tour parti pour dix
    /// minutes ne se rattrape plus.
    ///
    /// Un tour lancé depuis une liaison précédente compte aussi : c'est le cas
    /// après une veille du téléphone, et le seul moyen de reprendre la main sur
    /// un tour qu'on n'a pas soi-même envoyé.
    var isWorking: Bool { isPrompting || isRemoteTurnRunning }

    /// Vrai quand le relais annonce un tour en cours que cette liaison n'a pas
    /// lancé — typiquement celui qui tournait encore pendant la veille.
    private(set) var isRemoteTurnRunning = false

    /// Les demandes écrites pendant que l'agent travaille encore.
    ///
    /// Elles restent ici, au niveau du fil, plutôt que dans le composer : une
    /// rotation, une reconstruction SwiftUI ou la fermeture du clavier ne doit
    /// jamais perdre un message que l'interface a annoncé « en attente ».
    private(set) var queuedPromptCount = 0

    private struct QueuedPrompt {
        let text: String
        let attachments: [Attachment]
    }

    private var promptQueue: [QueuedPrompt] = []
    /// Une seule tâche vide la file. Sans ce verrou logique, deux taps rapides
    /// pourraient lancer deux `session/prompt` en parallèle sur le même fil.
    private var isDrainingPromptQueue = false

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
    /// L'ouverture d'un ancien fil reste hors écran jusqu'à ce que toutes les
    /// notifications de `session/load` aient traversé sa file FIFO.
    private var historySettlement: CheckedContinuation<Void, Never>?

    private let log = Logger(subsystem: "hublot", category: "session")
    private let environment: HublotEnvironment

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
        title: String, isResuming: Bool = false, status: SessionStatus? = nil,
        environment providedEnvironment: HublotEnvironment? = nil
    ) {
        let environment = providedEnvironment ?? .live
        self.environment = environment
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

    /// Attend la barrière placée derrière le rejeu par `ACPConnection`.
    /// Contrairement à un délai arbitraire, elle reste exacte quelle que soit
    /// la longueur du fil ou la vitesse de l'appareil.
    func finishReplay() async {
        guard isReplaying, let sessionId, pump != nil else { return }
        await withCheckedContinuation { continuation in
            historySettlement = continuation
            Task { await connection.finishHistory(session: sessionId) }
        }
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
        guard !trimmed.isEmpty || !attachments.isEmpty, sessionId != nil else { return }

        promptQueue.append(.init(text: trimmed, attachments: attachments))
        queuedPromptCount = promptQueue.count
        await drainPromptQueue()
    }

    /// Vide la file strictement dans l'ordre, et seulement quand aucun tour
    /// repris depuis le serveur ne possède encore la main.
    private func drainPromptQueue() async {
        guard !isDrainingPromptQueue, !isRemoteTurnRunning else { return }
        isDrainingPromptQueue = true
        defer { isDrainingPromptQueue = false }

        while !promptQueue.isEmpty, !isRemoteTurnRunning {
            let prompt = promptQueue.removeFirst()
            queuedPromptCount = promptQueue.count
            guard await perform(prompt) else { return }
        }
    }

    /// Exécute une seule demande. La séparation avec `send` est ce qui permet
    /// à l'appel public de ranger un message sans emboîter un second tour dans
    /// celui qui est déjà suspendu sur le réseau.
    private func perform(_ prompt: QueuedPrompt) async -> Bool {
        guard let sessionId else { return false }
        let trimmed = prompt.text
        let attachments = prompt.attachments

        isReplaying = false
        isPrompting = true
        // Le tour part d'ici : le battement précédent décrivait le tour d'avant,
        // et l'afficher ferait apparaître une durée déjà longue à la seconde
        // zéro.
        activity = .init(running: true, phase: .starting, engine: engine.rawValue)
        activityAt = environment.now()
        turns.append(
            .user(
                .init(
                    id: UUID().uuidString, text: trimmed,
                    images: attachments.map(\.jpeg)
                )
            )
        )
        // Dans la liste, le serveur garde son résumé persistant. Une fois le
        // fil ouvert, le titre sert plutôt à rappeler la demande à laquelle on
        // répond maintenant : sur une conversation longue, le nom du projet ou
        // la toute première question ne donnent plus ce repère.
        if !trimmed.isEmpty { title = Self.shorten(trimmed) }

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
            environment.notifyTurnFinished(title, lastAssistantText)
            return true
        } catch {
            finishStreaming(reason: nil)
            status = .failed(error.localizedDescription)
            return false
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
                try? await self?.environment.sleep(.seconds(5))
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
        historySettlement?.resume()
        historySettlement = nil
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
        // `isWorking` et non `isPrompting` : un tour lancé avant une veille se
        // rattrape aussi, et c'est même le seul moyen d'en reprendre la main.
        guard let sessionId, isWorking else { return }
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

            case .historyFinished(let id):
                guard id == sessionId else { continue }
                isReplaying = false
                historySettlement?.resume()
                historySettlement = nil

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
            // `session/load` rejoue les demandes dans l'ordre : en adoptant
            // chacune d'elles, le titre finit naturellement sur la plus
            // récente, comme lors d'un envoi en direct.
            title = Self.shorten(text)

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

        case .usage(let used, let size, let pushed, let at):
            contextUsed = used
            contextSize = size
            if let pushed { adopt(pushed) }
            contextHistory.append(
                .init(
                    id: "ctx-\(contextHistory.count)",
                    sequence: contextHistory.count,
                    used: used, size: size, at: at,
                    model: pushed?.model, engine: pushed?.engine
                )
            )

        case .activity(let beat):
            adopt(beat)

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

    /// Adopte un signe de vie.
    ///
    /// Le cas qui justifie tout ce chemin : on rouvre une conversation dont le
    /// tour n'est pas fini. Le rejeu vient de poser un texte figé ; ce battement
    /// dit qu'il s'écrit encore. Sans lui, l'app affichait une réponse
    /// apparemment terminée et un bouton d'envoi — alors que le moteur
    /// travaillait toujours et qu'aucun envoi ne serait accepté.
    private func adopt(_ beat: Activity) {
        activity = beat
        activityAt = environment.now()
        if let name = beat.engine, let known = Engine(rawValue: name) { engine = known }

        guard !isPrompting else { return }
        if beat.running {
            isRemoteTurnRunning = true
            // Ce qui arrive après ce point est vivant, pas archivé : les
            // morceaux suivants doivent donc battre du curseur.
            isReplaying = false
        } else if isRemoteTurnRunning {
            isRemoteTurnRunning = false
            finishStreaming(reason: beat.stopReason)
            environment.notifyTurnFinished(title, lastAssistantText)
            // Aucun appel local n'attend la fin d'un tour repris. Sa dernière
            // pulsation doit donc réveiller explicitement la file.
            Task { [weak self] in await self?.drainPromptQueue() }
        }
    }

    private func appendMessage(_ text: String, messageId: String) {
        if let index = messageIndex[messageId], case .assistant(var turn) = turns[index] {
            turn.append(text)
            // Le bloc rattrapé à la reprise d'un tour en vol est arrivé figé —
            // le relais l'avait rejoué avant de reprendre son flux. Dès qu'il
            // grandit à nouveau, il est vivant et doit le montrer.
            if isWorking && !turn.isStreaming { turn.isStreaming = true }
            turns[index] = .assistant(turn)
            return
        }
        // Un message rejoué est déjà écrit : le marquer « en cours » faisait
        // clignoter le curseur et respirer la lueur pour du texte figé, comme
        // si la machine travaillait alors qu'elle ne fait rien.
        //
        // `isWorking` et non `isPrompting` : le tour peut avoir été lancé avant
        // une veille du téléphone. C'est le même texte vivant, et il doit battre
        // du curseur qu'on l'ait demandé depuis cette liaison ou une autre.
        var turn = AssistantTurn(id: messageId, isStreaming: isWorking && !isReplaying)
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
            .thought(.init(
                id: messageId, markdown: text, isStreaming: isWorking && !isReplaying
            ))
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
            if let title = payload.title { turn.title = self.title(payload) ?? title }
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
                    title: title(payload) ?? payload.title ?? "outil",
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
    private func title(_ payload: ToolCallPayload) -> String? {
        if let path = payload.locations?.first?.path { return shorten(path) }
        if let command = payload.rawInput?["command"]?.stringValue { return command }
        // Le pont de Claude Code ne remplit pas `locations` : pour un `Edit`,
        // le chemin absolu arrive dans le titre. Sur un fil de cent trente
        // cartes, le préfixe du dépôt est le même partout et mange la largeur
        // utile — il ne reste plus la place de lire le nom du fichier.
        guard let title = payload.title else { return nil }
        return title.hasPrefix("/") ? shorten(title) : title
    }

    /// Un chemin ramené à ce qu'il dit d'utile : sa position dans le projet.
    ///
    /// Relatif plutôt que réduit au dernier composant — `UI/Blocks.swift` et
    /// `Domain/Blocks.swift` sont deux fichiers différents, et les confondre
    /// dans le fil rendrait le regroupement des appels répétés faux.
    private func shorten(_ path: String) -> String {
        let root = workingDirectory.hasSuffix("/") ? workingDirectory : workingDirectory + "/"
        if path.hasPrefix(root) { return String(path.dropFirst(root.count)) }
        return path
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
        isRemoteTurnRunning = false
        activity = nil
        activityAt = nil
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
        environment.notifyPermissionNeeded(turn.toolTitle, turn.detail)
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
