//
//  AppModelRecoveryTests.swift
//  Hublot
//
//  Ce que fait l'application quand la liaison ne se comporte pas bien : une
//  conversation reprise, un socket qui tombe pendant la veille, un retour au
//  premier plan sur un fil mort.
//
//  Les tests d'a cote couvrent le parcours nominal — se connecter, lister,
//  ouvrir. Celui-ci couvre les chemins de reprise, qui sont precisement ceux
//  qu'on ne voit jamais en developpement et qui decident de ce que voit
//  quelqu'un dont le telephone a dormi.
//

import Foundation
import Testing

@testable import IAClient_UI

@Suite("Reprise et retour au premier plan", .timeLimit(.minutes(1)))
@MainActor
struct AppModelRecoveryTests {

    // MARK: Reprendre une conversation

    @Test("Reprendre une conversation rejoue son historique et l'affiche")
    func resumeOpensTheRecordedThread() async throws {
        let transport = RecoveryTransport()
        let model = AppModel(environment: environment(for: transport))
        await model.connect()
        let project = try #require(model.projects.first { $0.name == "recent" })
        await model.open(project)
        let summary = try #require(model.sessions.first)

        await model.resume(summary)

        #expect(model.screen == .conversation)
        #expect(model.chat?.title == "Premier fil")
        #expect(await transport.methods().contains("session/load"))
    }

    @Test("Une reprise refusee ramene aux conversations en nommant le fil perdu")
    func failedResumeFallsBackToTheList() async throws {
        let transport = RecoveryTransport(failures: ["session/load"])
        let model = AppModel(environment: environment(for: transport))
        await model.connect()
        let project = try #require(model.projects.first { $0.name == "recent" })
        await model.open(project)
        let summary = try #require(model.sessions.first)

        await model.resume(summary)

        // Un ecran vide n'est jamais une reponse acceptable a un echec.
        #expect(model.screen == .sessions(project))
        #expect(model.chat == nil)
        #expect(model.failure?.contains("Premier fil") == true)
    }

    @Test("Une reconnexion remet en place le fil qu'on regardait")
    func reconnectionRestoresTheOpenConversation() async throws {
        // Le symptome repare ici : apres une coupure, l'ecran restait sur
        // `.conversation` avec un fil detruit par `teardown()`. Plus rien a
        // afficher, aucun bouton, et pour seule issue de tuer l'application.
        let transport = RecoveryTransport()
        let model = AppModel(environment: environment(for: transport))
        await model.connect()
        let project = try #require(model.projects.first { $0.name == "recent" })
        await model.open(project)
        await model.resume(try #require(model.sessions.first))
        #expect(model.chat != nil)

        // `connect()` commence par tout demonter : c'est exactement l'etat que
        // laisse une coupure subie.
        await model.connect()

        #expect(model.screen == .conversation)
        #expect(model.chat != nil)
        #expect(model.chat?.title == "Premier fil")
    }

    // MARK: Quitter un fil

    @Test("Fermer une conversation revient a son projet, pas a la liste des projets")
    func closingAConversationReturnsToItsProject() async throws {
        let transport = RecoveryTransport()
        let model = AppModel(environment: environment(for: transport))
        await model.connect()
        let project = try #require(model.projects.first { $0.name == "recent" })
        await model.open(project)
        await model.resume(try #require(model.sessions.first))

        model.closeConversation()

        // Enchainer deux fils sur le meme depot est le cas courant.
        #expect(model.screen == .sessions(project))
        #expect(model.chat == nil)
    }

    @Test("Le retour remonte d'un cran a chaque appui")
    func backWalksUpOneScreenAtATime() async throws {
        let transport = RecoveryTransport()
        let model = AppModel(environment: environment(for: transport))
        await model.connect()
        let project = try #require(model.projects.first { $0.name == "recent" })
        await model.open(project)
        await model.resume(try #require(model.sessions.first))

        model.back()
        #expect(model.screen == .sessions(project))

        model.back()
        #expect(model.screen == .projects)

        // Depuis les projets, il n'y a plus de cran au-dessus.
        model.back()
        #expect(model.screen == .projects)
    }

    @Test("Les reglages de liaison s'ouvrent a la demande et arretent la reprise")
    func settingsAreReachableOnDemand() async {
        let transport = RecoveryTransport()
        var environment = environment(for: transport)
        environment.sleep = { _ in try await Task.sleep(for: .seconds(3_600)) }
        let model = AppModel(environment: environment)
        await model.connect()

        model.showConnectionSettings()

        #expect(model.screen == .connection)
        #expect(model.isReconnecting == false)
    }

    // MARK: La liaison tombe

    @Test("Un socket qui meurt bascule en reprise sans renvoyer au formulaire")
    func aDeadSocketKeepsTheUserInPlace() async throws {
        let transport = RecoveryTransport()
        var environment = environment(for: transport)
        // La reprise ne doit pas aboutir pendant le test : on observe l'etat
        // « en train de reprendre », pas son issue.
        environment.sleep = { _ in try await Task.sleep(for: .seconds(3_600)) }
        let model = AppModel(environment: environment)
        await model.connect()
        #expect(model.screen == .projects)

        await transport.drop()

        #expect(await until { model.isReconnecting })
        // Le reglage est bon : c'est le reseau qui manque, pas l'utilisateur.
        #expect(model.screen == .projects)
        #expect(model.failure == nil)
    }

    @Test("Les plafonds pousses par la liaison sont retenus hors de toute conversation")
    func pushedStatusIsKeptOnTheConnection() async throws {
        let transport = RecoveryTransport()
        let model = AppModel(environment: environment(for: transport))
        await model.connect()

        await transport.emit(Self.usageFrame)

        #expect(await until { model.lastStatus != nil })
        #expect(model.lastStatus?.limits?["five_hour"]?.percent == 17)
        #expect(model.lastStatus?.engine == "claude")
    }

    // MARK: Retour au premier plan

    @Test("Un reveil sans liaison en ouvre une au lieu d'attendre")
    func foregroundWithoutConnectionReconnects() async {
        let transport = RecoveryTransport()
        let model = AppModel(environment: environment(for: transport))
        // Jamais connecte : l'ecran d'attente du lancement, liaison absente.
        #expect(model.screen == .launching)

        await model.handleForeground()

        #expect(model.screen == .projects)
        #expect(await transport.methods().contains("initialize"))
    }

    @Test("Un reveil sur liaison vivante se contente d'un test de vie")
    func foregroundOnLiveConnectionOnlyPings() async {
        let transport = RecoveryTransport()
        let model = AppModel(environment: environment(for: transport))
        await model.connect()
        let before = await transport.count(of: "initialize")

        await model.handleForeground()

        // Pas de seconde poignee de main : la liaison repond, on la garde.
        #expect(await transport.count(of: "initialize") == before)
        #expect(model.isReconnecting == false)
        #expect(model.screen == .projects)
    }

    @Test("Un reveil sur liaison morte refait la poignee de main")
    func foregroundOnDeadConnectionReconnects() async {
        // Le test de vie est le deuxieme `hublot/projects` : le premier est
        // celui du chargement initial.
        let transport = RecoveryTransport(failProjectsAtCall: 2)
        let model = AppModel(environment: environment(for: transport))
        await model.connect()
        let before = await transport.count(of: "initialize")

        await model.handleForeground()

        #expect(await transport.count(of: "initialize") == before + 1)
        #expect(model.screen == .projects)
    }

    @Test("Un reveil hors configuration ne touche a rien")
    func foregroundWithoutConfigurationDoesNothing() async {
        let transport = RecoveryTransport()
        var environment = HublotEnvironment.ephemeral(
            makeConnection: { _, _ in ACPConnection(transport: transport) }
        )
        environment.sleep = { _ in throw CancellationError() }
        let model = AppModel(environment: environment)

        await model.handleForeground()

        #expect(model.screen == .connection)
        #expect(await transport.methods().isEmpty)
    }

    // MARK: Les tours en cours

    @Test("Les tours en cours du relais peuplent les pastilles de l'accueil")
    func runningTurnsArePolled() async throws {
        let transport = RecoveryTransport()
        var environment = environment(for: transport)
        // Le sommeil interrompu borne la boucle a un seul passage.
        environment.sleep = { _ in throw CancellationError() }
        let model = AppModel(environment: environment)
        await model.connect()

        await model.watchRunning()

        #expect(model.running.map(\.sessionId) == ["session-a"])
        #expect(model.isRunning("session-a"))
        #expect(model.isRunning("session-b") == false)
        let project = try #require(model.projects.first { $0.name == "recent" })
        #expect(model.runningTurns(in: project).count == 1)
    }

    @Test("Une liste de tours indisponible garde la precedente au lieu de clignoter")
    func unavailableRunningListKeepsWhatWasKnown() async {
        let transport = RecoveryTransport()
        var environment = environment(for: transport)
        environment.sleep = { _ in throw CancellationError() }
        let model = AppModel(environment: environment)
        await model.connect()
        await model.watchRunning()
        #expect(model.running.count == 1)

        await transport.setFailures(["hublot/running"])
        await model.watchRunning()

        #expect(model.running.count == 1)
    }

    // MARK: Le banc

    private func environment(for transport: RecoveryTransport) -> HublotEnvironment {
        var environment = HublotEnvironment.ephemeral(
            serverURL: "ws://127.0.0.1:8765", token: "secret",
            makeConnection: { _, _ in ACPConnection(transport: transport) }
        )
        environment.sleep = { _ in throw CancellationError() }
        return environment
    }

    /// Laisse la pompe d'evenements consommer ce qui est en attente : lire
    /// l'etat juste apres avoir emis une trame reviendrait a le lire trop tot.
    private func until(_ condition: () -> Bool, limit: Int = 500) async -> Bool {
        for _ in 0..<limit {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private static let usageFrame = """
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-a",\
        "update":{"sessionUpdate":"usage_update","used":12000,"size":200000,\
        "_meta":{"hublot":{"model":"Opus 5","effort":"high","engine":"claude",\
        "limits":{"five_hour":{"percent":17,"resetsAt":"2026-08-09T04:00:00+00:00"}}}}}}}
        """
}

// MARK: - Un relais qu'on peut faire tomber

/// Le meme protocole que le vrai, avec trois leviers que le reseau ne donne
/// pas : couper la liaison, pousser une notification, et faire echouer une
/// methode precise a un appel precis.
private actor RecoveryTransport: ACPTransport {
    private var stream: AsyncThrowingStream<Data, Error>?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var recorded: [String] = []
    private var failures: Set<String>
    private let failProjectsAtCall: Int?
    private var projectCalls = 0

    init(failures: Set<String> = [], failProjectsAtCall: Int? = nil) {
        self.failures = failures
        self.failProjectsAtCall = failProjectsAtCall
    }

    var frames: AsyncThrowingStream<Data, Error> {
        if let stream { return stream }
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        return pair.stream
    }

    /// Un flux neuf a chaque ouverture : une reprise ne doit pas ecouter le
    /// precedent, mort depuis la coupure.
    func connect() async throws {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func disconnect() async {
        continuation?.finish()
    }

    /// La liaison meurt sans qu'on l'ait demande.
    func drop() {
        continuation?.finish()
    }

    func emit(_ line: String) {
        continuation?.yield(Data(line.utf8))
    }

    func setFailures(_ methods: Set<String>) {
        failures = methods
    }

    func methods() -> [String] { recorded }

    func count(of method: String) -> Int {
        recorded.filter { $0 == method }.count
    }

    func send(_ frame: Data) async throws {
        guard let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
            let method = object["method"] as? String
        else { return }
        recorded.append(method)
        if method == "hublot/projects" { projectCalls += 1 }
        guard let id = object["id"] as? Int else { return }

        let refused = failures.contains(method)
            || (method == "hublot/projects" && projectCalls == failProjectsAtCall)
        if refused {
            continuation?.yield(try JSONCoding.encoder.encode(RPCErrorReply(
                id: id, error: RPCError(code: -32010, message: "indisponible", data: nil)
            )))
            return
        }
        continuation?.yield(try JSONCoding.encoder.encode(RPCReply(
            id: id, result: result(for: method)
        )))
    }

    private func result(for method: String) -> JSONValue {
        switch method {
        case "initialize":
            .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object(["loadSession": .bool(true)]),
            ])
        case "hublot/projects":
            .object(["projects": .array([
                project("recent", "/root/repos/recent", "2026-08-08T00:00:00Z"),
                project("Tous les depots", "/root/repos", "2026-07-01T00:00:00Z"),
            ])])
        case "hublot/running":
            .object(["turns": .array([
                .object([
                    "sessionId": .string("session-a"),
                    "cwd": .string("/root/repos/recent"),
                    "engine": .string("claude"), "phase": .string("tool"),
                    "label": .string("pytest"), "elapsed": .number(12),
                    "quiet": .number(1),
                ])
            ])])
        case "session/list":
            .object(["sessions": .array([
                session("session-a", "Premier fil"), session("session-b", "Second fil"),
            ])])
        case "session/load":
            .object(["sessionId": .string("session-a"), "configOptions": .array([])])
        default:
            .object([:])
        }
    }

    private func project(_ name: String, _ path: String, _ date: String) -> JSONValue {
        .object([
            "name": .string(name), "path": .string(path), "sessionCount": .number(1),
            "updatedAt": .string(date),
        ])
    }

    private func session(_ id: String, _ title: String) -> JSONValue {
        .object([
            "sessionId": .string(id), "cwd": .string("/root/repos/recent"),
            "title": .string(title), "updatedAt": .string("2026-08-08T00:00:00Z"),
            "exchanges": .number(3),
        ])
    }
}
