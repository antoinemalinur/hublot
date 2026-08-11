import Foundation
import Testing

@testable import IAClient_UI

@Suite("Navigation et reprise de l'application", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct AppModelTests {
    @Test("Un demarrage vierge montre la connexion; un demarrage configure attend le serveur")
    func initialScreenFollowsStoredConfiguration() {
        let empty = AppModel(environment: .ephemeral())
        #expect(empty.screen == .connection)

        let configured = AppModel(environment: .ephemeral(
            serverURL: "ws://127.0.0.1:8765", token: "secret"
        ))
        #expect(configured.screen == .launching)
    }

    @Test("Une URL non WebSocket est refusee avant toute ouverture reseau")
    func invalidURLIsRejectedLocally() async {
        let transport = AppModelTransport()
        var environment = environment(for: transport)
        environment.readServerURL = { "https://example.invalid" }
        let model = AppModel(environment: environment)

        await model.connect()

        #expect(model.screen == .connection)
        #expect(model.failure?.contains("Adresse de serveur invalide") == true)
        #expect(await transport.methods().isEmpty)
    }

    @Test("La connexion charge, trie et affiche les projets sans service externe")
    func connectLoadsAndSortsProjects() async {
        let transport = AppModelTransport()
        var notificationRequests = 0
        var environment = environment(for: transport)
        environment.requestNotificationAuthorization = { notificationRequests += 1 }
        let model = AppModel(environment: environment)

        await model.connect()
        await Task.yield()

        #expect(model.screen == .projects)
        #expect(model.failure == nil)
        #expect(model.projects.map(\.path) == [
            "/root/repos", "/root/repos/recent", "/root/repos/older",
        ])
        #expect(notificationRequests == 1)
        #expect(await transport.methods().prefix(2) == ["initialize", "hublot/projects"])
    }

    @Test("Ouvrir un projet charge ensemble conversations et instructions")
    func openingProjectLoadsItsResources() async {
        let transport = AppModelTransport()
        let model = AppModel(environment: environment(for: transport))
        await model.connect()
        let project = try! #require(model.projects.first { $0.name == "recent" })

        await model.open(project)

        #expect(model.screen == .sessions(project))
        #expect(model.sessions.map(\.sessionId) == ["session-a", "session-b"])
        #expect(model.instructions?.content.contains("Tester chaque geste") == true)
        let methods = await transport.methods()
        #expect(methods.contains("session/list"))
        #expect(methods.contains("hublot/instructions"))
    }

    @Test("Un nom de projet est normalise avant de creer sa premiere conversation")
    func projectNameIsNormalised() async {
        let transport = AppModelTransport()
        let model = AppModel(environment: environment(for: transport))
        await model.connect()

        await model.createProject(named: "  mon/projet test  ")

        #expect(model.screen == .conversation)
        #expect(model.chat?.title == "mon-projet-test")
        #expect(await transport.newSessionDirectories() == ["/root/repos/mon-projet-test"])
    }

    @Test("Un nom vide apres normalisation reste sur place avec une erreur lisible")
    func invalidProjectNameIsVisible() async {
        let transport = AppModelTransport()
        let model = AppModel(environment: environment(for: transport))
        await model.connect()

        await model.createProject(named: " /.- ")

        #expect(model.screen == .projects)
        #expect(model.failure == "Nom de projet invalide.")
        #expect(!(await transport.methods()).contains("session/new"))
    }

    @Test("Supprimer une conversation appelle le serveur puis retire immediatement la rangee")
    func deletionMutatesTheVisibleList() async {
        let transport = AppModelTransport()
        let model = AppModel(environment: environment(for: transport))
        await model.connect()
        let project = try! #require(model.projects.first { $0.name == "recent" })
        await model.open(project)
        let removed = try! #require(model.sessions.first)

        await model.delete(removed)

        #expect(model.sessions.map(\.sessionId) == ["session-b"])
        #expect((await transport.methods()).contains("session/delete"))
    }

    @Test("Une liste de conversations refusee devient un etat vide avec erreur")
    func sessionListFailureIsVisible() async {
        let transport = AppModelTransport(profile: .sessionListFailure)
        let model = AppModel(environment: environment(for: transport))
        await model.connect()
        let project = try! #require(model.projects.first { $0.name == "recent" })

        await model.open(project)

        #expect(model.sessions.isEmpty)
        #expect(model.failure?.isEmpty == false)
    }

    @Test("Une liste qui charge ne rend pas les boutons de l'ecran inertes")
    func loadingTheListKeepsTheScreenUsable() async throws {
        // « L'app est lente sur les clics » : un même drapeau `isBusy` servait
        // aux actions et au simple rechargement de la liste. En arrivant sur un
        // projet, « Nouvelle conversation » restait donc désactivé tant que le
        // serveur n'avait pas répondu — le bouton ne réagissait pas, alors que
        // rien n'empêchait de le toucher.
        let transport = AppModelTransport(profile: .pausedSessionList)
        let model = AppModel(environment: environment(for: transport))
        await model.connect()
        let project = try #require(model.projects.first { $0.name == "recent" })

        let opening = Task { await model.open(project) }
        while !(await transport.methods()).contains("session/list") {
            await Task.yield()
        }

        // La liste est en vol : c'est exactement l'instant du reproche.
        #expect(model.isLoadingSessions)
        #expect(model.isBusy == false)

        try await transport.releaseSessionList()
        await opening.value

        #expect(model.isLoadingSessions == false)
        #expect(model.sessions.map(\.sessionId) == ["session-a", "session-b"])
    }

    @Test("Un jeton refuse revient au formulaire; une panne temporaire reste en reprise")
    func authenticationAndTemporaryFailureAreDifferent() async {
        let rejected = AppModelTransport(profile: .rejected)
        let rejectedModel = AppModel(environment: environment(for: rejected))
        await rejectedModel.connect()
        #expect(rejectedModel.screen == .connection)
        #expect(rejectedModel.failure == "Jeton refusé par le serveur.")

        let offline = AppModelTransport(profile: .offline)
        var offlineEnvironment = environment(for: offline)
        offlineEnvironment.sleep = { _ in throw CancellationError() }
        let offlineModel = AppModel(environment: offlineEnvironment)
        await offlineModel.connect()
        #expect(offlineModel.screen == .launching)
        #expect(offlineModel.isReconnecting)
    }

    @Test("La deconnexion volontaire oublie le fil et revient aux reglages")
    func disconnectReturnsToSettings() async {
        let transport = AppModelTransport()
        let model = AppModel(environment: environment(for: transport))
        await model.connect()

        await model.disconnect()

        #expect(model.screen == .connection)
        #expect(await transport.wasDisconnected())
    }

    private func environment(for transport: AppModelTransport) -> HublotEnvironment {
        var environment = HublotEnvironment.ephemeral(
            serverURL: "ws://127.0.0.1:8765", token: "secret",
            makeConnection: { _, _ in ACPConnection(transport: transport) }
        )
        environment.sleep = { _ in throw CancellationError() }
        return environment
    }
}

private actor AppModelTransport: ACPTransport {
    enum Profile: Sendable, Equatable {
        case happy
        case rejected
        case offline
        case sessionListFailure
        /// `session/list` reste sans réponse jusqu'à `releaseSessionList()` :
        /// c'est la fenêtre pendant laquelle l'écran doit rester utilisable.
        case pausedSessionList
    }

    private let profile: Profile
    private var stream: AsyncThrowingStream<Data, Error>?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var recordedMethods: [String] = []
    private var recordedDirectories: [String] = []
    private var disconnected = false
    private var heldSessionList: Int?

    init(profile: Profile = .happy) { self.profile = profile }

    var frames: AsyncThrowingStream<Data, Error> {
        if let stream { return stream }
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        return pair.stream
    }

    func connect() async throws {
        if profile == .offline { throw TransportError.notConnected }
        _ = frames
    }

    func disconnect() async {
        disconnected = true
        continuation?.finish()
    }

    func send(_ frame: Data) async throws {
        let value = try JSONSerialization.jsonObject(with: frame)
        guard let object = value as? [String: Any],
              let method = object["method"] as? String
        else { return }
        recordedMethods.append(method)
        if method == "session/new",
           let params = object["params"] as? [String: Any],
           let cwd = params["cwd"] as? String {
            recordedDirectories.append(cwd)
        }
        guard let id = object["id"] as? Int else { return }

        if profile == .rejected, method == "initialize" {
            continuation?.yield(try JSONCoding.encoder.encode(RPCErrorReply(
                id: id, error: RPCError(code: -32000, message: "refuse", data: nil)
            )))
            return
        }
        if profile == .pausedSessionList, method == "session/list" {
            heldSessionList = id
            return
        }
        if profile == .sessionListFailure, method == "session/list" {
            continuation?.yield(try JSONCoding.encoder.encode(RPCErrorReply(
                id: id, error: RPCError(code: -32010, message: "historique indisponible", data: nil)
            )))
            return
        }
        continuation?.yield(try JSONCoding.encoder.encode(RPCReply(
            id: id, result: result(for: method)
        )))
    }

    /// Laisse enfin repartir la liste mise en attente.
    func releaseSessionList() throws {
        guard let id = heldSessionList else { return }
        heldSessionList = nil
        continuation?.yield(try JSONCoding.encoder.encode(RPCReply(
            id: id, result: result(for: "session/list")
        )))
    }

    func methods() -> [String] { recordedMethods }
    func newSessionDirectories() -> [String] { recordedDirectories }
    func wasDisconnected() -> Bool { disconnected }

    private func result(for method: String) -> JSONValue {
        switch method {
        case "initialize":
            .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([
                    "loadSession": .bool(true),
                    "sessionCapabilities": .object(["list": .object([:]), "resume": .object([:])]),
                ]),
            ])
        case "hublot/projects":
            .object(["projects": .array([
                project("older", "/root/repos/older", "2026-08-01T00:00:00Z"),
                project("Tous les depots", "/root/repos", "2026-07-01T00:00:00Z"),
                project("recent", "/root/repos/recent", "2026-08-08T00:00:00Z"),
            ])])
        case "hublot/running":
            .object(["turns": .array([])])
        case "session/list":
            .object(["sessions": .array([
                session("session-a", "Premier fil"), session("session-b", "Second fil"),
            ])])
        case "hublot/instructions":
            .object(["instructions": .object([
                "path": .string("/root/repos/recent/AGENTS.md"),
                "content": .string("Tester chaque geste avant livraison."),
                "bytes": .number(38),
                "updatedAt": .string("2026-08-08T00:00:00Z"),
            ])])
        case "session/new":
            .object(["sessionId": .string("new-session"), "configOptions": .array([])])
        default:
            .object([:])
        }
    }

    private func project(_ name: String, _ path: String, _ date: String) -> JSONValue {
        .object([
            "name": .string(name), "path": .string(path), "sessionCount": .number(2),
            "updatedAt": .string(date),
        ])
    }

    private func session(_ id: String, _ title: String) -> JSONValue {
        .object([
            "sessionId": .string(id), "cwd": .string("/root/repos/recent"),
            "title": .string(title), "updatedAt": .string("2026-08-08T00:00:00Z"),
            "exchanges": .number(2),
        ])
    }
}
