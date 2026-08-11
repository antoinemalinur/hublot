//
//  ChatSessionSettingsTests.swift
//  Hublot
//
//  Les chemins du fil que le rejeu d'une capture ne traverse pas : ecrire un
//  reglage, repondre a une demande de permission, dire pourquoi un tour s'est
//  arrete, transcrire une dictee, reprendre la main sur un tour parti.
//
//  Ils ont un point commun : ce sont tous des allers-retours declenches par
//  quelqu'un devant l'ecran, pas par l'agent. Aucun n'apparait dans un fichier
//  de trames enregistrees, et c'est pour ca qu'ils manquaient.
//

import Foundation
import Testing

@testable import IAClient_UI

@Suite("Reglages, permissions et fins de tour", .timeLimit(.minutes(1)))
@MainActor
struct ChatSessionSettingsTests {

    // MARK: Les reglages

    @Test("Un reglage accepte adopte la liste que l'agent renvoie")
    func acceptedSettingAdoptsTheReturnedList() async throws {
        let transport = ScriptedTransport(replies: [
            "session/set_config_option": Self.options(current: "sonnet")
        ])
        let bench = try await Bench(transport: transport)
        bench.chat.apply(try Self.setup())
        let option = try #require(bench.chat.configOptions.first)
        #expect(option.currentValueString == "opus")

        await bench.chat.choose(option, value: "sonnet")

        #expect(bench.chat.configOptions.first?.currentValueString == "sonnet")
        #expect(bench.chat.settingRejected == nil)
        #expect(await transport.methods().contains("session/set_config_option"))
    }

    @Test("Un reglage refuse laisse l'interface sur ce qu'elle avait obtenu")
    func rejectedSettingIsSaidInsteadOfFaked() async throws {
        let transport = ScriptedTransport(failures: ["session/set_config_option"])
        let bench = try await Bench(transport: transport)
        bench.chat.apply(try Self.setup())
        let option = try #require(bench.chat.configOptions.first)

        await bench.chat.choose(option, value: "sonnet")

        // Ne jamais montrer un etat qu'on n'a pas obtenu.
        #expect(bench.chat.configOptions.first?.currentValueString == "opus")
        #expect(bench.chat.settingRejected?.contains("Modele") == true)
    }

    @Test("Rechoisir la valeur courante ne parle pas au serveur")
    func choosingTheSameValueIsANoop() async throws {
        let transport = ScriptedTransport()
        let bench = try await Bench(transport: transport)
        bench.chat.apply(try Self.setup())
        let option = try #require(bench.chat.configOptions.first)

        await bench.chat.choose(option, value: "opus")

        #expect(await transport.methods().contains("session/set_config_option") == false)
    }

    @Test("Un moteur en cours verrouille ses réglages jusqu'à sa fin")
    func activeTurnRejectsASettingChangeLocally() async throws {
        let transport = ScriptedTransport(replies: [
            "session/set_config_option": Self.options(current: "sonnet")
        ])
        let bench = try await Bench(transport: transport)
        bench.chat.apply(try Self.setup())
        let option = try #require(bench.chat.configOptions.first)
        await transport.emit(Self.activity(
            Bench.sessionId, #""running":true,"phase":"tool","engine":"codex","elapsed":8,"quiet":1"#
        ))
        #expect(await bench.until { bench.chat.isWorking })

        await bench.chat.choose(option, value: "sonnet")

        #expect(bench.chat.configOptions.first?.currentValueString == "opus")
        #expect(await transport.methods().contains("session/set_config_option") == false)
    }

    // MARK: Les permissions

    @Test("Une demande de permission dit ce que l'agent s'apprete vraiment a faire")
    func permissionShowsTheRealCommand() async throws {
        let transport = ScriptedTransport()
        let bench = try await Bench(transport: transport)

        // Quatre facons dont le detail arrive selon l'implementation en face.
        await transport.emit(Self.permission(
            id: 1, tool: "cmd", title: "Bash",
            body: #""rawInput":{"command":"pytest -q"}"#
        ))
        await transport.emit(Self.permission(
            id: 2, tool: "edit", title: "Edit",
            body: #""rawInput":{"file_path":"/root/repos/demo/app.py"}"#
        ))
        await transport.emit(Self.permission(
            id: 3, tool: "read", title: "Read",
            body: #""locations":[{"path":"/root/repos/demo/README.md"}]"#
        ))
        await transport.emit(Self.permission(id: 4, tool: "bare", title: "Outil nu", body: nil))

        #expect(await bench.until { bench.permissions.count == 4 })
        #expect(bench.permissions.map(\.detail) == [
            "pytest -q", "/root/repos/demo/app.py",
            "/root/repos/demo/README.md", "Outil nu",
        ])
    }

    @Test("Le choix touche part vers l'agent")
    func touchedChoiceReachesTheAgent() async throws {
        let transport = ScriptedTransport()
        let bench = try await Bench(transport: transport)
        await transport.emit(Self.permission(
            id: 7, tool: "cmd", title: "Bash",
            body: #""rawInput":{"command":"rm -rf build"}"#
        ))
        #expect(await bench.until { bench.permissions.isEmpty == false })
        let request = try #require(bench.permissions.first)

        await request.respond?("once")

        #expect(await bench.until { await transport.answered().contains(7) })
    }

    // MARK: Les fins de tour

    @Test("Un tour qui ne finit pas de lui-meme le dit dans le fil")
    func abnormalStopReasonsAreWrittenDown() async throws {
        let expected: [(StopReason, String)] = [
            (.cancelled, "interrompu"),
            (.refusal, "refusé par le moteur"),
            (.maxTokens, "coupé : réponse trop longue"),
            (.maxTurnRequests, "coupé : trop d'allers-retours"),
        ]

        for (reason, text) in expected {
            let bench = try await Bench(transport: ScriptedTransport())
            await bench.connection.finishTurn(session: Bench.sessionId, reason: reason)

            #expect(await bench.until { bench.notices.isEmpty == false })
            #expect(bench.notices.first?.text == text)
        }
    }

    @Test("Un tour termine normalement n'ecrit rien")
    func normalEndOfTurnStaysSilent() async throws {
        let bench = try await Bench(transport: ScriptedTransport())

        await bench.connection.finishTurn(session: Bench.sessionId, reason: .endTurn)

        // Rien a dire : le cas normal ne merite pas une ligne dans le fil. On
        // laisse quand meme la pompe tourner, sinon l'absence ne prouve rien.
        _ = await bench.until({ false }, limit: 100)
        #expect(bench.notices.isEmpty)
    }

    // MARK: La dictee et l'arret

    @Test("Une dictee revient en texte, jamais directement dans le fil")
    func dictationReturnsTextToTheCaller() async throws {
        let transport = ScriptedTransport(replies: [
            "hublot/transcribe": #"{"text":"résume le dernier tour"}"#
        ])
        let bench = try await Bench(transport: transport)

        let text = try await bench.chat.transcribe(Data("audio".utf8))

        #expect(text == "résume le dernier tour")
        #expect(bench.chat.turns.isEmpty)
    }

    @Test("On reprend la main sur un tour lance avant la veille")
    func remoteTurnCanBeCancelled() async throws {
        let transport = ScriptedTransport()
        let bench = try await Bench(transport: transport)
        // Rien ne tourne : il n'y a rien a arreter.
        await bench.chat.cancel()
        #expect(await transport.methods().contains("session/cancel") == false)

        await transport.emit(Self.activity(
            Bench.sessionId, #""running":true,"phase":"tool","elapsed":90,"quiet":2"#
        ))
        #expect(await bench.until { bench.chat.isWorking })

        await bench.chat.cancel()

        #expect(await bench.until { await transport.methods().contains("session/cancel") })
    }

    @Test("Les messages ecrits pendant un tour partent ensuite, un par un")
    func promptsQueueBehindTheCurrentTurn() async throws {
        let transport = HeldPromptTransport()
        let connection = ACPConnection(transport: transport)
        try await connection.start()
        let chat = ChatSession(
            connection: connection, events: await connection.subscribe(),
            workingDirectory: "/root/repos/demo", sessionId: Bench.sessionId,
            title: "demo", environment: .ephemeral()
        )

        let first = Task { await chat.send("Premiere demande") }
        #expect(await eventually { await transport.promptCount() == 1 })
        #expect(chat.isWorking)

        // Les appels suivants rendent la main tout de suite : ils ne doivent
        // ni parler au serveur, ni apparaître comme déjà envoyés dans le fil.
        await chat.send("Deuxieme demande")
        await chat.send("Troisieme demande")
        #expect(chat.queuedPromptCount == 2)
        #expect(await transport.promptCount() == 1)
        #expect(userTexts(in: chat) == ["Premiere demande"])

        await transport.finishNextPrompt()
        #expect(await eventually { await transport.promptCount() == 2 })
        #expect(chat.queuedPromptCount == 1)
        #expect(userTexts(in: chat) == ["Premiere demande", "Deuxieme demande"])

        await transport.finishNextPrompt()
        #expect(await eventually { await transport.promptCount() == 3 })
        #expect(chat.queuedPromptCount == 0)
        #expect(userTexts(in: chat) == [
            "Premiere demande", "Deuxieme demande", "Troisieme demande",
        ])

        await transport.finishNextPrompt()
        await first.value
        #expect(!chat.isWorking)
    }

    @Test("La fin d'un tour repris reveille la file locale")
    func queuedPromptStartsAfterRemoteTurnFinishes() async throws {
        let transport = HeldPromptTransport()
        let connection = ACPConnection(transport: transport)
        try await connection.start()
        let chat = ChatSession(
            connection: connection, events: await connection.subscribe(),
            workingDirectory: "/root/repos/demo", sessionId: Bench.sessionId,
            title: "demo", environment: .ephemeral()
        )

        await transport.emit(Self.activity(
            Bench.sessionId, #""running":true,"phase":"thinking","elapsed":12,"quiet":1"#
        ))
        #expect(await eventually { chat.isWorking })

        await chat.send("A envoyer au retour")
        #expect(chat.queuedPromptCount == 1)
        #expect(await transport.promptCount() == 0)

        await transport.emit(Self.activity(
            Bench.sessionId,
            #""running":false,"phase":"done","elapsed":15,"quiet":0,"stopReason":"end_turn""#
        ))
        #expect(await eventually { await transport.promptCount() == 1 })
        #expect(userTexts(in: chat) == ["A envoyer au retour"])

        await transport.finishNextPrompt()
        #expect(await eventually { !chat.isWorking })
    }

    private func eventually(_ condition: () async -> Bool, limit: Int = 500) async -> Bool {
        for _ in 0..<limit {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

    private func userTexts(in chat: ChatSession) -> [String] {
        chat.turns.compactMap { turn in
            if case .user(let user) = turn { return user.text }
            return nil
        }
    }

    @Test("Ouvrir le fil ouvre la liaison qui le porte")
    func startingTheThreadOpensTheLink() async throws {
        let transport = ScriptedTransport()
        let bench = try await Bench(transport: transport)

        try await bench.chat.start()

        #expect(await transport.connections() == 2)
    }

    // MARK: Ce que l'agent pense et prevoit

    @Test("Une reflexion en plusieurs morceaux reste un seul bloc")
    func thoughtChunksMergeIntoOneTurn() async throws {
        let transport = ScriptedTransport()
        let bench = try await Bench(transport: transport)

        await transport.emit(Self.thought(Bench.sessionId, id: "t1", text: "Je regarde "))
        await transport.emit(Self.thought(Bench.sessionId, id: "t1", text: "la base."))
        // Un identifiant different ouvre bien un second bloc.
        await transport.emit(Self.thought(Bench.sessionId, id: "t2", text: "Puis je conclus."))

        #expect(await bench.until { bench.thoughts.count == 2 })
        #expect(bench.thoughts.map(\.markdown) == ["Je regarde la base.", "Puis je conclus."])
    }

    @Test("Le plan annonce par l'agent devient une liste ordonnee")
    func planBecomesAnOrderedList() async throws {
        let transport = ScriptedTransport()
        let bench = try await Bench(transport: transport)

        await transport.emit("""
            {"jsonrpc":"2.0","method":"session/update","params":{
              "sessionId":"\(Bench.sessionId)","update":{"sessionUpdate":"plan","entries":[
                {"content":"Lire la base","status":"completed"},
                {"content":"Ecrire le test","status":"in_progress"},
                {"content":"Livrer","status":"pending"}]}}}
            """)

        #expect(await bench.until { bench.chat.plan.count == 3 })
        #expect(bench.chat.plan.map(\.id) == ["plan-0", "plan-1", "plan-2"])
        #expect(bench.chat.plan.map(\.status) == [.completed, .inProgress, .pending])
    }

    @Test("Un outil qui rend un diff ou un terminal garde sa forme")
    func toolContentKeepsItsShape() async throws {
        let transport = ScriptedTransport()
        let bench = try await Bench(transport: transport)

        await transport.emit("""
            {"jsonrpc":"2.0","method":"session/update","params":{
              "sessionId":"\(Bench.sessionId)","update":{"sessionUpdate":"tool_call",
              "toolCallId":"edit-1","title":"app.py","kind":"edit","status":"completed",
              "content":[
                {"type":"diff","path":"/root/repos/demo/app.py",
                 "oldText":"a = 1","newText":"a = 2"},
                {"type":"terminal","terminalId":"term-9"},
                {"type":"inconnu"}]}}}
            """)

        #expect(await bench.until { bench.tools.isEmpty == false })
        let call = try #require(bench.tools.first)
        // La variante inconnue est ecartee, les deux autres restent.
        #expect(call.content.count == 2)
        guard case .diff(_, let path, let oldText, let newText) = call.content[0] else {
            Issue.record("le premier contenu n'est pas un diff")
            return
        }
        #expect(path == "/root/repos/demo/app.py")
        #expect(oldText == "a = 1")
        #expect(newText == "a = 2")
        guard case .terminal(let id, _) = call.content[1] else {
            Issue.record("le second contenu n'est pas un terminal")
            return
        }
        #expect(id == "term-9")
    }

    // MARK: Le banc

    @MainActor
    final class Bench {
        static let sessionId = "session-reglages"
        let connection: ACPConnection
        let chat: ChatSession

        init(transport: ScriptedTransport) async throws {
            connection = ACPConnection(transport: transport)
            try await connection.start()
            chat = ChatSession(
                connection: connection, events: await connection.subscribe(),
                workingDirectory: "/root/repos/demo", sessionId: Self.sessionId,
                title: "demo", environment: .ephemeral()
            )
        }

        var permissions: [PermissionTurn] {
            chat.turns.compactMap { if case .permission(let turn) = $0 { turn } else { nil } }
        }

        var notices: [NoticeTurn] {
            chat.turns.compactMap { if case .notice(let turn) = $0 { turn } else { nil } }
        }

        var thoughts: [ThoughtTurn] {
            chat.turns.compactMap { if case .thought(let turn) = $0 { turn } else { nil } }
        }

        var tools: [ToolCallTurn] {
            chat.turns.compactMap { if case .toolCall(let turn) = $0 { turn } else { nil } }
        }

        func until(_ condition: () async -> Bool, limit: Int = 500) async -> Bool {
            for _ in 0..<limit {
                if await condition() { return true }
                await Task.yield()
            }
            return await condition()
        }
    }

    private static func setup() throws -> SessionSetup {
        try JSONCoding.decoder.decode(
            SessionSetup.self, from: Data(options(current: "opus").utf8)
        )
    }

    /// La forme que l'agent donne a ses reglages : identifiant, libelle, valeur
    /// courante et choix possibles. Sert d'etat de depart et de reponse.
    private static func options(current: String) -> String {
        """
        {"sessionId":"\(Bench.sessionId)",\
        "configOptions":[{"id":"model","name":"Modele","type":"select",\
        "currentValue":"\(current)","options":[{"value":"opus","name":"Opus"},\
        {"value":"sonnet","name":"Sonnet"}]}]}
        """
    }

    private static func permission(
        id: Int, tool: String, title: String, body: String?
    ) -> String {
        let extra = body.map { ",\($0)" } ?? ""
        return """
            {"jsonrpc":"2.0","id":\(id),"method":"session/request_permission","params":{
              "sessionId":"\(Bench.sessionId)",
              "toolCall":{"toolCallId":"\(tool)","title":"\(title)","kind":"execute"\(extra)},
              "options":[{"optionId":"once","name":"Autoriser une fois","kind":"allow_once"}]}}
            """
    }

    private static func thought(_ session: String, id: String, text: String) -> String {
        """
        {"jsonrpc":"2.0","method":"session/update","params":{
          "sessionId":"\(session)","update":{"sessionUpdate":"agent_thought_chunk",
          "messageId":"\(id)","content":{"type":"text","text":"\(text)"}}}}
        """
    }

    private static func activity(_ session: String, _ body: String) -> String {
        """
        {"jsonrpc":"2.0","method":"session/update","params":{
          "sessionId":"\(session)","update":{"sessionUpdate":"hublot_activity",\(body)}}}
        """
    }
}

// MARK: - Un relais qu'on ecrit a l'avance

/// Repond ce qu'on lui a dicte, methode par methode, et note ce qu'il a recu.
/// Les demandes venues de l'agent — les permissions — passent par `emit`.
actor ScriptedTransport: ACPTransport {
    private var stream: AsyncThrowingStream<Data, Error>?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private let replies: [String: String]
    private let failures: Set<String>
    private var recorded: [String] = []
    private var answeredIds: [Int] = []
    private var opened = 0

    init(replies: [String: String] = [:], failures: Set<String> = []) {
        self.replies = replies
        self.failures = failures
    }

    var frames: AsyncThrowingStream<Data, Error> {
        if let stream { return stream }
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        return pair.stream
    }

    func connect() async throws {
        opened += 1
        _ = frames
    }

    func disconnect() async { continuation?.finish() }

    func emit(_ line: String) { continuation?.yield(Data(line.utf8)) }

    func methods() -> [String] { recorded }
    func answered() -> [Int] { answeredIds }
    func connections() -> Int { opened }

    func send(_ frame: Data) async throws {
        guard let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any]
        else { return }

        // Une reponse a une demande de l'agent : pas de methode, juste un
        // identifiant et un resultat.
        guard let method = object["method"] as? String else {
            if let id = object["id"] as? Int { answeredIds.append(id) }
            return
        }
        recorded.append(method)
        guard let id = object["id"] as? Int else { return }

        if failures.contains(method) {
            continuation?.yield(try JSONCoding.encoder.encode(RPCErrorReply(
                id: id, error: RPCError(code: -32020, message: "refuse", data: nil)
            )))
            return
        }
        let result = replies[method] ?? "{}"
        continuation?.yield(Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8))
    }
}

/// Garde les réponses de `session/prompt` jusqu'à ce que le test les libère.
/// C'est la seule manière de prouver qu'un deuxième message n'est pas parti en
/// parallèle : un relais qui répond immédiatement ne laisse aucune file vivre.
actor HeldPromptTransport: ACPTransport {
    private var stream: AsyncThrowingStream<Data, Error>?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var promptIDs: [Int] = []
    private var nextPromptToFinish = 0

    var frames: AsyncThrowingStream<Data, Error> {
        if let stream { return stream }
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        return pair.stream
    }

    func connect() async throws { _ = frames }
    func disconnect() async { continuation?.finish() }

    func emit(_ line: String) { continuation?.yield(Data(line.utf8)) }
    func promptCount() -> Int { promptIDs.count }

    func finishNextPrompt() {
        guard promptIDs.indices.contains(nextPromptToFinish) else { return }
        let id = promptIDs[nextPromptToFinish]
        nextPromptToFinish += 1
        continuation?.yield(Data(
            #"{"jsonrpc":"2.0","id":\#(id),"result":{"stopReason":"end_turn"}}"#.utf8
        ))
    }

    func send(_ frame: Data) async throws {
        guard
            let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
            let method = object["method"] as? String,
            let id = object["id"] as? Int
        else { return }

        if method == "session/prompt" {
            promptIDs.append(id)
        } else {
            continuation?.yield(Data(
                #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#.utf8
            ))
        }
    }
}
