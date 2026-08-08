//
//  ConversationFlowTests.swift
//  Hublot
//
//  Le fil, assemblé à partir de **vraies trames**.
//
//  Ce fichier existe parce qu'il manquait. Les tests d'à côté vérifiaient que
//  chaque trame se décode ; aucun ne vérifiait ce qu'on en fait. Or le bug qui a
//  gâché un tour entier sur l'iPhone était exactement là : le décodage était
//  bon, l'assemblage recevait une trame sur deux.
//
//  La cause : `ACPConnection.events` était **un** `AsyncStream` partagé. Un
//  `AsyncStream` est mono-consommateur — chaque élément va chez *un* itérateur,
//  pas chez tous. Dès la deuxième conversation ouverte, deux boucles tiraient
//  sur le même flux et chacune jetait ce qui ne portait pas son `sessionId`.
//  À l'écran : un outil sans titre, un `tool_call_update` promu en appel neuf
//  et donc affiché « Other », et une réponse qui s'arrête au milieu.
//
//  D'où la forme de ces tests : ils ouvrent **deux** fils, comme dans la main,
//  et rejouent la capture d'un vrai tour (`Fixtures/tour-office-chess.jsonl`,
//  relevée le 6 août 2026 contre le VPS).
//

import Foundation
import Testing

@testable import IAClient_UI

@Suite("Assemblage du fil", .timeLimit(.minutes(1)))
struct ConversationFlowTests {

    // MARK: Le tour complet

    @Test("Un tour réel produit le fil entier, même avec un autre fil ouvert")
    func fullTurnSurvivesASecondSession() async throws {
        let harness = try await Harness()

        // La condition qui cassait tout : une conversation déjà ouverte ailleurs.
        let other = await harness.session(id: "une-autre-session")
        let chat = await harness.session(id: harness.recordedSession)

        await chat.send("D'après la bdd qui est le gagnant du tournois ?")
        let turns = await chat.turns

        // La question, puis l'annonce, puis cinq commandes, puis la réponse.
        let userTurns = turns.compactMap { if case .user(let t) = $0 { t } else { nil } }
        #expect(userTurns.count == 1)

        let assistant = turns.compactMap { if case .assistant(let t) = $0 { t } else { nil } }
        let prose = assistant.map(\.markdown).joined(separator: "\n")
        #expect(prose.contains("I'll look at the database."))
        // La fin du tour, celle qui n'arrivait jamais à l'écran.
        #expect(prose.contains("La base ne désigne aucun gagnant"))
        #expect(prose.contains("calendrier des 12 matchs prévus."))

        let tools = turns.compactMap { if case .toolCall(let t) = $0 { t } else { nil } }
        // Cinq commandes, pas une de plus : un `tool_call_update` reçu sans son
        // `tool_call` fabriquait un appel fantôme.
        #expect(tools.count == 5)
        // Le symptôme le plus lisible sur la capture d'Antoine : une ligne
        // « Other » alors que toutes ces commandes sont des exécutions.
        #expect(tools.allSatisfy { $0.kind == .execute })
        #expect(tools.allSatisfy { $0.status == .completed })
        // Le titre doit être la commande, pas le nom générique de l'outil.
        #expect(tools.allSatisfy { $0.title != "Bash" })
        #expect(tools.first?.title == "ls -la /root/repos/office-chess")

        // Et l'autre fil n'a rien attrapé qui ne le regardait pas.
        #expect(await other.turns.isEmpty)
    }

    @Test("Le fil rendu ne porte jamais deux fois le même identifiant")
    func turnIdentitiesAreUnique() async throws {
        // Un doublon d'identifiant dans un `ForEach` fait décrocher le rendu :
        // SwiftUI en garde un et abandonne l'autre, sans rien dire.
        let harness = try await Harness()
        let chat = await harness.session(id: harness.recordedSession)
        await chat.send("D'après la bdd qui est le gagnant du tournois ?")

        let ids = await chat.turns.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Le fil garde l'ordre réel : ce que l'agent a fait avant ce qu'il en dit")
    func chronologyIsPreserved() async throws {
        // Le serveur donnait le même `messageId` à tout un tour. Les morceaux de
        // texte arrivés après les outils retrouvaient donc le tour ouvert
        // **avant** eux et s'y collaient : la conclusion s'affichait au-dessus
        // des commandes qui l'avaient produite.
        let harness = try await Harness("tour-ordre")
        let chat = await harness.session(id: harness.recordedSession)
        await chat.send("Combien de joueurs dans la bdd ?")

        let shape = await chat.turns.map { turn -> String in
            switch turn {
            case .user: "user"
            case .assistant: "assistant"
            case .thought: "thought"
            case .toolCall: "outil"
            case .permission: "permission"
            case .notice: "notice"
            }
        }
        #expect(shape.first == "user")
        let firstTool = try #require(shape.firstIndex(of: "outil"))
        let lastTool = try #require(shape.lastIndex(of: "outil"))
        let lastAssistant = try #require(shape.lastIndex(of: "assistant"))

        // L'annonce précède les commandes, la conclusion les suit.
        #expect(shape[1] == "assistant")
        #expect(firstTool > 1)
        #expect(lastAssistant > lastTool)

        let answer = await chat.turns.compactMap {
            if case .assistant(let t) = $0 { t.markdown } else { nil }
        }
        #expect(answer.first?.contains("I'll look at the database.") == true)
        #expect(answer.last?.contains("4 joueurs") == true)
    }

    @Test("Le titre du fil suit le dernier prompt envoyé")
    func titleFollowsLatestLivePrompt() async throws {
        let harness = try await Harness()
        let chat = await harness.session(id: harness.recordedSession)

        await chat.send("Vérifie le premier état")
        #expect(await chat.title == "Vérifie le premier état")

        let latest = "Résume la dernière modification et les tests associés"
        await chat.send(latest)
        #expect(await chat.title == latest)
    }

    @Test("La reprise d'un fil finit sur le dernier prompt rejoué")
    @MainActor
    func titleFollowsLatestReplayedPrompt() async throws {
        let harness = try await Harness()
        let chat = await harness.session(id: harness.recordedSession)

        await harness.transport.emit(Self.userMessage(
            harness.recordedSession, id: "question-1", text: "Ancienne demande"
        ))
        await harness.transport.emit(Self.userMessage(
            harness.recordedSession, id: "question-2", text: "Dernière demande rejouée"
        ))

        #expect(await harness.until { chat.title == "Dernière demande rejouée" })
    }

    @Test("La reprise attend que tout l'historique soit assemblé avant de paraître")
    @MainActor
    func replayBarrierDrainsHistoryBeforePresentation() async throws {
        let harness = try await Harness()
        let chat = await harness.session(id: harness.recordedSession, isResuming: true)

        let setup = try await harness.connection.call(
            "session/load",
            LoadSessionParams(
                sessionId: harness.recordedSession,
                cwd: "/root/repos/office-chess"
            ),
            as: SessionSetup.self
        )
        chat.apply(setup)
        await chat.finishReplay()

        let prose = chat.turns.compactMap {
            if case .assistant(let turn) = $0 { turn.markdown } else { nil }
        }.joined(separator: "\n")
        #expect(prose.contains("La base ne désigne aucun gagnant"))
        #expect(chat.turns.contains {
            if case .toolCall = $0 { return true }
            return false
        })
    }

    @Test("Un lot d'outils se replie une fois par type d'action")
    func toolRowsGroupByKindWithinAContiguousBatch() throws {
        let turns: [Turn] = [
            .toolCall(.init(id: "edit-1", title: "app.py", kind: .edit, status: .completed)),
            .toolCall(.init(id: "read-1", title: "README.md", kind: .read, status: .completed)),
            .toolCall(.init(id: "edit-2", title: "styles.css", kind: .edit, status: .completed)),
            .assistant(.init(id: "answer", markdown: "Terminé.")),
            .toolCall(.init(id: "read-2", title: "Tests.swift", kind: .read, status: .completed)),
        ]

        let rows = turns.threadRows()
        #expect(rows.count == 4)
        guard case .tools(let edits) = rows[0], case .tools(let reads) = rows[1],
            case .single = rows[2], case .tools(let finalRead) = rows[3]
        else {
            Issue.record("la frontière de prose ou l'ordre des types n'est pas conservé")
            return
        }
        #expect(edits.kind == .edit)
        #expect(edits.calls.map(\.id) == ["edit-1", "edit-2"])
        #expect(reads.kind == .read)
        #expect(reads.calls.map(\.id) == ["read-1"])
        #expect(finalRead.calls.map(\.id) == ["read-2"])
    }

    // MARK: L'état de la machine

    @Test("Un échec rattrapé n'alarme plus l'écran une fois la réponse rendue")
    func recoveredFailureDoesNotStickRed() {
        // Vu à l'écran : une commande refusée en milieu de tour peignait le fond
        // en rouge, et il y restait — y compris après une réponse complète.
        let failed = Turn.toolCall(
            .init(id: "a", title: "sqlite3 …", kind: .execute, status: .failed)
        )
        let recovered = Turn.toolCall(
            .init(id: "b", title: "python3 …", kind: .execute, status: .completed)
        )
        let answer = Turn.assistant(.init(id: "m", markdown: "La cadence est 5+2."))

        #expect(MachineState.derive(from: [failed, recovered, answer]) == .idle)
        #expect(MachineState.derive(from: [failed, recovered]) == .idle)
        // En revanche, un échec qui est le dernier mot reste un échec.
        #expect(MachineState.derive(from: [recovered, failed]) == .failed)
    }

    @Test("Ce qui travaille l'emporte sur ce qui est fini")
    func liveWorkWins() {
        let running = Turn.toolCall(
            .init(id: "a", title: "pytest", kind: .execute, status: .inProgress)
        )
        let done = Turn.toolCall(
            .init(id: "b", title: "ls", kind: .execute, status: .failed)
        )
        #expect(MachineState.derive(from: [done, running]) == .working)

        var streaming = AssistantTurn(id: "m", isStreaming: true)
        streaming.append("j'écris")
        #expect(MachineState.derive(from: [done, .assistant(streaming)]) == .thinking)
    }

    // MARK: Le moteur affiché

    @Test("La pastille du moteur suit celui que le serveur a résolu")
    func engineFollowsTheServer() async throws {
        // `engine` était posé à `.claude` à la construction et plus jamais
        // touché : choisir Codex basculait bien le VPS, et la pastille à côté du
        // nom du dépôt continuait d'annoncer Claude.
        let harness = try await Harness()
        let chat = await harness.session(id: harness.recordedSession)
        #expect(await chat.engine == .claude)

        await harness.transport.emit(
            Harness.usageFrame.replacingOccurrences(
                of: "\"engine\":\"claude\"", with: "\"engine\":\"codex\""
            )
        )
        #expect(await harness.until { chat.engine == .codex })
    }

    // MARK: Le cycle de vie

    @Test("Une conversation fermée cesse de consommer les trames")
    func closedSessionStopsReading() async throws {
        let harness = try await Harness()
        let abandoned = await harness.session(id: harness.recordedSession)
        await abandoned.disconnect()

        let chat = await harness.session(id: harness.recordedSession)
        await chat.send("D'après la bdd qui est le gagnant du tournois ?")

        #expect(await abandoned.turns.isEmpty)
        #expect(await !chat.turns.isEmpty)
    }

    // MARK: Les plafonds

    @Test("Les plafonds poussés avant l'ouverture d'un fil ne sont pas perdus")
    func statusPushedBeforeTheSessionExists() async throws {
        // Le serveur envoie `usage_update` **avant** de répondre l'identifiant
        // de la session : à cet instant aucun fil n'écoute encore. C'est pour ça
        // que la barre de statut restait vide jusqu'à la fin du premier tour.
        let harness = try await Harness()
        let observed = await harness.connection.subscribe()

        await harness.transport.emit(Harness.usageFrame)

        var received: SessionStatus?
        for await event in observed {
            if case .update(let notification) = event,
                case .usage(_, _, let pushed, _) = notification.update
            {
                received = pushed
                break
            }
        }

        let status = try #require(received)
        #expect(status.fiveHour?.percent == 17)
        // Le décompte dépend de l'heure qu'il est : on vérifie la forme, pas
        // la valeur — sinon le test se périme tout seul.
        let bar = try #require(StatusBar.content(status: status, contextPercent: 8))
        #expect(bar.hasPrefix("5H: 17% · \(StatusBar.reset)"))
        #expect(bar.hasSuffix(" · CTX 8%"))
        #expect(bar.components(separatedBy: " · ").count == 3)
    }

    @Test("Un fil ouvert reprend les plafonds déjà connus de la liaison")
    func sessionSeedsFromKnownStatus() async throws {
        let harness = try await Harness()
        let notification = try JSONCoding.decoder.decode(
            RelayedUpdate.self, from: Data(Harness.usageFrame.utf8)
        ).params
        guard case .usage(_, _, let pushed, _) = notification.update else {
            Issue.record("la trame de plafonds n'est pas un usage_update")
            return
        }

        let chat = await harness.session(id: harness.recordedSession, status: pushed)
        #expect(await chat.metrics?.fiveHour?.percent == 17)
    }

    @Test("Une mesure de contexte impossible n'affiche jamais plus de cent pour cent")
    @MainActor
    func impossibleContextIsHidden() async throws {
        let harness = try await Harness()
        let chat = await harness.session(id: harness.recordedSession)

        await harness.transport.emit(Self.usage(
            harness.recordedSession, used: 100, size: 100
        ))
        #expect(await harness.until { chat.contextPercent == 100 })

        await harness.transport.emit(Self.usage(
            harness.recordedSession, used: 1_540, size: 100
        ))
        #expect(await harness.until { chat.contextUsed == 1_540 })
        #expect(chat.contextPercent == nil)
    }

    @Test("Chaque mesure de contexte reste dans le fil, y compris l'incohérente")
    @MainActor
    func everyMeasurementIsKept() async throws {
        let harness = try await Harness()
        let chat = await harness.session(id: harness.recordedSession)

        await harness.transport.emit(Self.usage(
            harness.recordedSession, used: 12_000, size: 200_000,
            at: "2026-08-08T10:00:00.000Z"
        ))
        await harness.transport.emit(Self.usage(
            harness.recordedSession, used: 84_000, size: 200_000,
            at: "2026-08-08T10:02:00.000Z"
        ))
        // Celle-ci est impossible — c'est le bug réel où le serveur envoyait le
        // total des jetons d'un tour. Le fil la garde quand même : c'est la
        // marée qui décide de ce qu'elle sait tracer, pas l'enregistreur.
        await harness.transport.emit(Self.usage(
            harness.recordedSession, used: 900_000, size: 200_000
        ))

        #expect(await harness.until { chat.contextHistory.count == 3 })

        let history = chat.contextHistory
        #expect(history.map(\.used) == [12_000, 84_000, 900_000])
        #expect(history[0].at != nil)
        // Sans horodatage sur la liaison, l'échantillon existe quand même.
        #expect(history[2].at == nil)

        // Le tracé, lui, écarte l'incohérente sans la ramener de force à cent.
        let tide = ContextTide(samples: history)
        #expect(tide.plottable.map(\.used) == [12_000, 84_000])
        #expect(tide.snapshot().current?.percent == 42)
    }

    @Test("Une session Codex affiche son quota, jamais le cinq heures Claude")
    func codexStatusUsesCodexWindow() throws {
        let status = try JSONCoding.decoder.decode(
            SessionStatus.self,
            from: Data(
                """
                {"model":"gpt-5.6-sol","effort":"max","engine":"codex",\
                 "limits":{"seven_day":{"percent":20,\
                 "resetsAt":"2026-08-11T00:13:37+00:00"}}}
                """.utf8
            )
        )

        let bar = try #require(StatusBar.content(status: status, contextPercent: nil))
        #expect(bar.hasPrefix("7J: 20% · \(StatusBar.reset)"))
        #expect(!bar.contains("5H"))

        // Chaque jauge porte son seuil : à 20 % le quota reste discret, une
        // fenêtre de contexte à 92 % doit alarmer.
        let cells = StatusBar.cells(status: status, contextPercent: 92)
        #expect(cells.map(\.percent) == [20, nil, 92])
        #expect(StatusBar.tint(20) == Hublot.meta)
        #expect(StatusBar.tint(92) == Hublot.removed)
        #expect(status.model == "gpt-5.6-sol")
        #expect(status.effort == "max")
    }

    @Test("Codex montre sa semaine même quand il annonce aussi une fenêtre courte")
    func codexPrefersItsWeeklyWindow() throws {
        // Ce compte n'expose que l'hebdomadaire, mais rien ne garantit que ça
        // dure. La barre demandait le 5 h en premier : le jour où les deux
        // arrivent ensemble, elle affichait une semaine sous « 5H ».
        let status = try JSONCoding.decoder.decode(
            SessionStatus.self,
            from: Data(
                """
                {"model":"gpt-5.6-sol","effort":"max","engine":"codex",\
                 "limits":{"five_hour":{"percent":3,\
                 "resetsAt":"2026-08-09T02:00:00+00:00"},\
                 "seven_day":{"percent":64,\
                 "resetsAt":"2026-08-11T00:13:37+00:00"}}}
                """.utf8
            )
        )

        let bar = try #require(StatusBar.content(status: status, contextPercent: nil))
        #expect(bar.hasPrefix("7J: 64%"))
        #expect(!bar.contains("5H"))

        // Claude, lui, est plafonné par sa session : la préférence est inverse,
        // et une même barre doit savoir dire les deux.
        let claude = try JSONCoding.decoder.decode(
            SessionStatus.self,
            from: Data(
                """
                {"model":"opus","effort":"high","engine":"claude",\
                 "limits":{"five_hour":{"percent":52,\
                 "resetsAt":"2026-08-09T01:10:00+00:00"},\
                 "seven_day":{"percent":92,\
                 "resetsAt":"2026-08-10T17:00:00+00:00"}}}
                """.utf8
            )
        )
        let claudeBar = try #require(StatusBar.content(status: claude, contextPercent: nil))
        #expect(claudeBar.hasPrefix("5H: 52%"))
        #expect(!claudeBar.contains("7J"))
    }

    // MARK: Un tour qui a survécu à la veille

    /// Le scénario exact vécu sur Office Chess : une demande longue, le
    /// téléphone qui s'endort, la liaison qui tombe, et l'app qui revient.
    ///
    /// Avant, elle revenait sur un fil muet : le tour continuait côté serveur
    /// mais écrivait vers un socket mort, et rien à l'écran ne disait s'il
    /// travaillait encore ou s'il était planté. On attendait devant une réponse
    /// qui n'arrivait plus, sans moyen de trancher.
    @Test("Un tour resté en vol se voit dès la reprise, et sa fin se dit")
    @MainActor
    func liveTurnSurvivesReconnection() async throws {
        let harness = try await Harness()
        let chat = await harness.session(id: harness.recordedSession)
        #expect(chat.isWorking == false)

        await harness.transport.emit(Self.activity(
            harness.recordedSession,
            #""running":true,"phase":"tool","label":"sqlite3 manual.db","#
                + #""engine":"codex","elapsed":137.4,"quiet":12.3"#
        ))

        #expect(await harness.until { chat.isWorking })
        #expect(chat.activity?.phase == .tool)
        #expect(chat.activity?.label == "sqlite3 manual.db")
        #expect(chat.activityAt != nil)
        // Le moteur annoncé par le battement fait autorité : la pastille
        // affichait Claude pendant que Codex répondait.
        #expect(chat.engine == .codex)

        // Ce qui arrive ensuite est vivant, pas de l'archive : le curseur doit
        // battre, sinon on relit une réponse en la croyant finie.
        await harness.transport.emit(
            """
            {"jsonrpc":"2.0","method":"session/update","params":{
              "sessionId":"\(harness.recordedSession)","update":{
                "sessionUpdate":"agent_message_chunk","messageId":"en-vol",
                "content":{"type":"text","text":"La sauvegarde est saine."}}}}
            """
        )
        #expect(await harness.until {
            chat.turns.contains {
                if case .assistant(let turn) = $0 { return turn.isStreaming }
                return false
            }
        })

        await harness.transport.emit(Self.activity(
            harness.recordedSession,
            #""running":false,"phase":"done","elapsed":420,"quiet":0.2,"#
                + #""stopReason":"end_turn""#
        ))

        #expect(await harness.until { !chat.isWorking })
        #expect(await harness.until {
            chat.turns.allSatisfy {
                if case .assistant(let turn) = $0 { return !turn.isStreaming }
                return true
            }
        })
        // Le battement s'efface avec le tour : une durée figée à l'écran
        // laisserait croire à un travail en cours.
        #expect(chat.activity == nil)
    }

    @Test("Le battement d'un autre fil ne fait pas travailler celui-ci")
    @MainActor
    func activityIsFilteredBySession() async throws {
        let harness = try await Harness()
        let mine = await harness.session(id: harness.recordedSession)
        let other = await harness.session(id: "une-autre-session")

        await harness.transport.emit(Self.activity(
            "une-autre-session", #""running":true,"phase":"writing","elapsed":3,"quiet":0.1"#
        ))

        #expect(await harness.until { other.isWorking })
        #expect(mine.isWorking == false)
        #expect(mine.activity == nil)
    }

    private static func activity(_ session: String, _ body: String) -> String {
        """
        {"jsonrpc":"2.0","method":"session/update","params":{
          "sessionId":"\(session)","update":{"sessionUpdate":"hublot_activity",\(body)}}}
        """
    }

    private static func userMessage(_ session: String, id: String, text: String) -> String {
        """
        {"jsonrpc":"2.0","method":"session/update","params":{
          "sessionId":"\(session)","update":{"sessionUpdate":"user_message_chunk",
          "messageId":"\(id)","content":{"type":"text","text":"\(text)"}}}}
        """
    }

    private static func usage(
        _ session: String, used: Int, size: Int, at: String? = nil
    ) -> String {
        // L'horodatage est facultatif dans le protocole : les fils enregistrés
        // avant son introduction n'en portent pas, et la trame doit rester
        // décodable sans lui.
        let stamp = at.map { #","ts":"\#($0)""# } ?? ""
        return """
            {"jsonrpc":"2.0","method":"session/update","params":{
              "sessionId":"\(session)","update":{"sessionUpdate":"usage_update",
              "used":\(used),"size":\(size)\(stamp)}}}
            """
    }

    /// L'enveloppe d'une notification, pour lire la charge d'une trame de test.
    struct RelayedUpdate: Decodable {
        let params: SessionNotification
    }
}

// MARK: - Le banc

/// Une liaison complète — connexion, multiplexage, fils — adossée à un rejeu de
/// trames enregistrées plutôt qu'à un serveur.
///
/// Tout le chemin est le vrai : `ACPConnection`, `ChatSession`, le décodage. Le
/// seul élément remplacé est le WebSocket, et c'est précisément ce qu'on ne
/// cherche pas à tester ici.
@MainActor
final class Harness {
    static let sessionID = "3363726b-1528-4349-82b7-651cf2f2831f"

    static let usageFrame = """
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"\(sessionID)",\
        "update":{"sessionUpdate":"usage_update","used":0,"size":1000000,\
        "_meta":{"hublot":{"model":"Opus 4.8","effort":"low","engine":"claude",\
        "limits":{"five_hour":{"percent":17,"resetsAt":"2026-08-07T04:00:00.769920+00:00"},\
        "seven_day":{"percent":56,"resetsAt":"2026-08-10T17:00:00.769944+00:00"}}}}}}}
        """

    let transport: ReplayTransport
    let connection: ACPConnection
    /// Celui de la capture rejouée, pas une constante : chaque enregistrement
    /// porte la session qui l'a produit, et le fil filtre là-dessus.
    let recordedSession: String

    init(_ fixture: String = "tour-office-chess") async throws {
        let frames = try Self.recording(fixture)
        recordedSession = Self.sessionID(in: frames) ?? Self.sessionID
        transport = ReplayTransport(frames: frames)
        connection = ACPConnection(transport: transport)
        try await connection.start()
    }

    private static func sessionID(in frames: [String]) -> String? {
        struct Envelope: Decodable {
            struct Params: Decodable { let sessionId: String? }
            let params: Params?
        }
        for frame in frames {
            let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(frame.utf8))
            if let id = envelope?.params?.sessionId { return id }
        }
        return nil
    }

    /// Laisse la boucle de lecture consommer ce qui est en attente. Les
    /// événements sont tamponnés, et la pompe est une tâche distincte : lire
    /// l'état juste après avoir émis une trame reviendrait à la lire trop tôt.
    func until(_ condition: () -> Bool, limit: Int = 500) async -> Bool {
        for _ in 0..<limit {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    func session(
        id: String, status: SessionStatus? = nil, isResuming: Bool = false
    ) async -> ChatSession {
        ChatSession(
            connection: connection, events: await connection.subscribe(),
            workingDirectory: "/root/repos/office-chess", sessionId: id,
            title: "office-chess", isResuming: isResuming, status: status
        )
    }

    /// La capture, lue à côté de ce fichier. Une trace réelle vaut mieux qu'une
    /// trame écrite à la main : celle-ci contient les redites et le désordre que
    /// le serveur produit vraiment.
    private static func recording(_ name: String) throws -> [String] {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/\(name).jsonl")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }
}

/// Rejoue une capture. À la première demande de tour, il déroule les
/// notifications enregistrées puis rend le `stopReason` — dans l'ordre exact où
/// le serveur les a émises.
actor ReplayTransport: ACPTransport {
    private let recorded: [String]
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var stream: AsyncThrowingStream<Data, Error>?

    init(frames: [String]) {
        self.recorded = frames
    }

    var frames: AsyncThrowingStream<Data, Error> {
        if let stream { return stream }
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.stream = stream
        self.continuation = continuation
        return stream
    }

    func connect() async throws {
        _ = frames
    }

    func disconnect() async {
        continuation?.finish()
    }

    /// Émet une trame telle quelle — pour les cas où c'est le calendrier qui est
    /// testé, pas le contenu.
    func emit(_ line: String) {
        continuation?.yield(Data(line.utf8))
    }

    func send(_ frame: Data) async throws {
        guard
            let outgoing = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
            let method = outgoing["method"] as? String
        else { return }

        switch method {
        case "session/prompt", "session/load":
            for line in recorded where line.contains("\"method\"") {
                continuation?.yield(Data(line.utf8))
            }
            if let id = outgoing["id"] as? Int {
                let result = method == "session/prompt"
                    ? #"{"stopReason":"end_turn"}"#
                    : "{}"
                continuation?.yield(Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8))
            }
        default:
            if let id = outgoing["id"] as? Int {
                continuation?.yield(Data(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#.utf8))
            }
        }
    }
}
