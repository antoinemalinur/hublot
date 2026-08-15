//
//  ScreenFixtures.swift
//  Hublot
//
//  Les états déterministes des écrans de liste, de connexion et d'attente.
//
//  Ils ne vivent que dans la version de développement, et chacun est atteint par
//  au moins un test : une fixture que personne n'exerce ne prouve rien et fait
//  baisser la couverture de la cible qui la porte.
//
//  Deux mécanismes, jamais mélangés. Les états qui ne vérifient qu'un affichage
//  portent des **données figées** — c'est le plus court chemin vers un écran
//  toujours identique. Ceux qui vérifient un aller-retour portent un **relais
//  témoin** : un transport ACP complet qui répond comme le VPS, parce qu'un test
//  qui affirme le résultat que la fixture lui a soufflé ne teste rien.
//

#if DEBUG
    import SwiftUI

    // MARK: - Navigation

    /// Le parcours d'entrée, de bout en bout : dépôts → conversations → fil, et
    /// tous les retours, y compris la déconnexion.
    ///
    /// Aucune de ces navigations n'était vérifiée. C'est pourtant le chemin que
    /// chaque session emprunte : une régression y rend l'app inutilisable, et
    /// aucune autre vérification ne se joue.
    struct NavigationFixture: View {
        @State private var model: AppModel

        init() {
            let transport = NavigationTransport()
            var environment = HublotEnvironment.ephemeral(
                serverURL: "ws://127.0.0.1:8330", token: "ui-test",
                makeConnection: { _, _ in ACPConnection(transport: transport) }
            )
            environment.sleep = { duration in try await Task.sleep(for: duration) }
            _model = State(initialValue: AppModel(environment: environment))
        }

        var body: some View {
            // Le même aiguillage que `RootView` : c'est lui qu'on vérifie.
            Group {
                switch model.screen {
                case .launching:
                    HoldingView(purpose: .launching) { model.showConnectionSettings() }
                case .connection:
                    ConnectionView(model: model)
                case .projects:
                    ProjectsView(model: model)
                case .sessions(let project):
                    SessionsView(model: model, project: project)
                case .conversation:
                    if let chat = model.chat {
                        ConversationView(
                            sessionTitle: chat.title, engine: chat.engine,
                            turns: chat.turns,
                            onBack: { model.closeConversation() },
                            onDictate: { _ in nil }
                        )
                    } else {
                        HoldingView(purpose: .reconnecting) { model.closeConversation() }
                    }
                }
            }
            .task { await model.connect() }
        }
    }

    /// Un dépôt, une conversation reprenable. Le minimum pour que chaque
    /// navigation ait une destination et un retour.
    private actor NavigationTransport: ACPTransport {
        private let stream: AsyncThrowingStream<Data, Error>
        private let continuation: AsyncThrowingStream<Data, Error>.Continuation

        init() {
            let pair = AsyncThrowingStream<Data, Error>.makeStream()
            stream = pair.stream
            continuation = pair.continuation
        }

        var frames: AsyncThrowingStream<Data, Error> { stream }
        func connect() async throws {}
        func disconnect() async { continuation.finish() }

        func send(_ frame: Data) async throws {
            guard let request = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
                let method = request["method"] as? String,
                let id = request["id"] as? Int
            else { return }

            switch method {
            case "initialize":
                reply(id, [
                    "protocolVersion": 1,
                    "agentCapabilities": [
                        "loadSession": true,
                        "sessionCapabilities": ["list": [:], "resume": [:]],
                    ],
                ])
            case "hublot/projects":
                reply(id, ["projects": [[
                    "name": "hublot", "path": "/root/repos/hublot",
                    "sessionCount": 1, "updatedAt": "2026-08-12T09:15:00.000Z",
                ]]])
            case "session/list":
                reply(id, ["sessions": [[
                    "sessionId": "fil-a-reprendre", "cwd": "/root/repos/hublot",
                    "title": "Reprendre le fil", "updatedAt": "2026-08-12T09:15:00.000Z",
                    "exchanges": 3,
                ]]])
            case "session/load":
                reply(id, ["configOptions": []])
            case "hublot/running":
                reply(id, ["turns": []])
            case "hublot/instructions":
                reply(id, ["instructions": NSNull()])
            default:
                reply(id, [:])
            }
        }

        private func reply(_ id: Int, _ result: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "result": result,
            ]) else { return }
            continuation.yield(data)
        }
    }

    // MARK: - Connexion

    /// Une connexion qui ne rend jamais la main : le bouton doit annoncer qu'il
    /// travaille et refuser un second toucher.
    struct ConnectionBusyFixture: View {
        @State private var model: AppModel

        init() {
            var environment = HublotEnvironment.ephemeral(
                serverURL: "ws://127.0.0.1:8331", token: "ui-test",
                makeConnection: { _, _ in ACPConnection(transport: SilentTransport()) }
            )
            environment.sleep = { duration in try await Task.sleep(for: duration) }
            _model = State(initialValue: AppModel(environment: environment))
        }

        var body: some View {
            ConnectionView(model: model)
                .task { await model.connect() }
        }
    }

    /// Le seul relais témoin autorisé à dormir : ici, l'attente **est** le sujet.
    private actor SilentTransport: ACPTransport {
        private let stream: AsyncThrowingStream<Data, Error>

        init() {
            stream = AsyncThrowingStream<Data, Error>.makeStream().stream
        }

        var frames: AsyncThrowingStream<Data, Error> { stream }
        /// L'ouverture ne s'achève jamais — comme un VPS injoignable qui laisse
        /// la poignée de main en suspens.
        func connect() async throws { try await Task.sleep(for: .seconds(3_600)) }
        func disconnect() async {}
        func send(_ frame: Data) async throws {}
    }

    /// Le serveur refuse le jeton. La panne doit s'écrire sous les champs, et le
    /// formulaire rester là — c'est le seul cas où on le remontre.
    struct ConnectionFailureFixture: View {
        @State private var model: AppModel

        init() {
            var environment = HublotEnvironment.ephemeral(
                serverURL: "ws://127.0.0.1:8332", token: "jeton-perime",
                makeConnection: { _, _ in ACPConnection(transport: RejectingTransport()) }
            )
            environment.sleep = { duration in try await Task.sleep(for: duration) }
            _model = State(initialValue: AppModel(environment: environment))
        }

        var body: some View {
            ConnectionView(model: model)
                .task { await model.connect() }
        }
    }

    /// `-32000` : le code par lequel le relais dit « ce porteur n'est pas le
    /// mien ». C'est le seul refus qui doive ramener au formulaire.
    private actor RejectingTransport: ACPTransport {
        private let stream: AsyncThrowingStream<Data, Error>
        private let continuation: AsyncThrowingStream<Data, Error>.Continuation

        init() {
            let pair = AsyncThrowingStream<Data, Error>.makeStream()
            stream = pair.stream
            continuation = pair.continuation
        }

        var frames: AsyncThrowingStream<Data, Error> { stream }
        func connect() async throws {}
        func disconnect() async { continuation.finish() }

        func send(_ frame: Data) async throws {
            guard let request = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
                let id = request["id"] as? Int
            else { return }
            guard let data = try? JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id,
                "error": ["code": -32_000, "message": "token refused"],
            ]) else { return }
            continuation.yield(data)
        }
    }

    // MARK: - Dépôts

    /// Les quatre formes qu'une rangée de dépôt peut prendre, sur le même écran :
    /// vide, à une seule conversation, au travail, et débordante de nom.
    struct ProjectsVariantsFixture: View {
        @State private var model: AppModel

        /// Le nom qui déborde. Un vrai dépôt cloné depuis un miroir en porte de
        /// cette longueur, et la rangée doit alors tronquer le **nom** — jamais
        /// le chevron, qui est ce sur quoi on appuie.
        static let longName =
            "infrastructure-de-validation-continue-avec-un-nom-vraiment-tres-long"

        init() {
            let projects: [ProjectListResult.Project] = [
                .init(name: "depot-vide", path: "/root/repos/depot-vide",
                      sessionCount: 0, updatedAt: .now.addingTimeInterval(-7_200)),
                .init(name: "depot-unique", path: "/root/repos/depot-unique",
                      sessionCount: 1, updatedAt: .now.addingTimeInterval(-3_600)),
                .init(name: "depot-actif", path: "/root/repos/depot-actif",
                      sessionCount: 4, updatedAt: .now.addingTimeInterval(-600)),
                .init(name: "depot-occupe", path: "/root/repos/depot-occupe",
                      sessionCount: 9, updatedAt: .now.addingTimeInterval(-300)),
                .init(name: Self.longName, path: "/root/repos/\(Self.longName)",
                      sessionCount: 2, updatedAt: .now.addingTimeInterval(-1_800)),
            ]
            let running: [RunningResult.Turn] = [
                .init(sessionId: "actif-1", cwd: "/root/repos/depot-actif",
                      engine: "claude", phase: .tool, label: "pytest",
                      elapsed: 134, quiet: 1),
                .init(sessionId: "occupe-1", cwd: "/root/repos/depot-occupe",
                      engine: "claude", phase: .tool, label: "pytest",
                      elapsed: 65, quiet: 1),
                .init(sessionId: "occupe-2", cwd: "/root/repos/depot-occupe",
                      engine: "codex", phase: .thinking, label: "validation",
                      elapsed: 200, quiet: 2),
            ]
            _model = State(initialValue: .demo(projects: projects, running: running))
        }

        var body: some View { ProjectsView(model: model) }
    }

    /// La liste tirée vers le bas doit vraiment redemander au serveur. Le relais
    /// répond deux choses différentes : sans quoi un rechargement qui ne
    /// rechargerait rien passerait pour un succès.
    struct ProjectsReloadFixture: View {
        @State private var model: AppModel

        init() {
            let transport = ReloadTransport()
            var environment = HublotEnvironment.ephemeral(
                serverURL: "ws://127.0.0.1:8333", token: "ui-test",
                makeConnection: { _, _ in ACPConnection(transport: transport) }
            )
            environment.sleep = { duration in try await Task.sleep(for: duration) }
            _model = State(initialValue: AppModel(environment: environment))
        }

        var body: some View {
            ProjectsView(model: model)
                .task { await model.connect() }
        }
    }

    private actor ReloadTransport: ACPTransport {
        private let stream: AsyncThrowingStream<Data, Error>
        private let continuation: AsyncThrowingStream<Data, Error>.Continuation
        private var reads = 0

        init() {
            let pair = AsyncThrowingStream<Data, Error>.makeStream()
            stream = pair.stream
            continuation = pair.continuation
        }

        var frames: AsyncThrowingStream<Data, Error> { stream }
        func connect() async throws {}
        func disconnect() async { continuation.finish() }

        func send(_ frame: Data) async throws {
            guard let request = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
                let method = request["method"] as? String,
                let id = request["id"] as? Int
            else { return }

            switch method {
            case "initialize":
                reply(id, [
                    "protocolVersion": 1,
                    "agentCapabilities": ["loadSession": true,
                                          "sessionCapabilities": ["list": [:]]],
                ])
            case "hublot/projects":
                reads += 1
                let name = reads <= 1 ? "avant-rechargement" : "apres-rechargement"
                reply(id, ["projects": [[
                    "name": name, "path": "/root/repos/\(name)",
                    "sessionCount": reads, "updatedAt": "2026-08-12T09:15:00.000Z",
                ]]])
            case "hublot/running":
                reply(id, ["turns": []])
            default:
                reply(id, [:])
            }
        }

        private func reply(_ id: Int, _ result: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "result": result,
            ]) else { return }
            continuation.yield(data)
        }
    }

    // MARK: - Attente

    /// L'écran d'attente et son issue de secours.
    ///
    /// Au lancement, le bouton passe par le vrai chemin de l'app —
    /// `showConnectionSettings()` — et doit donc faire apparaître le formulaire.
    /// C'est l'écran blanc sans sortie qui a fait exister ce bouton.
    struct HoldingLaunchFixture: View {
        @State private var model = AppModel(environment: .ephemeral(
            serverURL: "ws://127.0.0.1:8334", token: "ui-test"
        ))

        var body: some View {
            Group {
                if model.screen == .connection {
                    ConnectionView(model: model)
                } else {
                    HoldingView(purpose: .launching) { model.showConnectionSettings() }
                }
            }
        }
    }

    /// La reprise en cours de route : pas de nom d'app, et une sortie qui ramène
    /// aux conversations.
    struct HoldingReconnectFixture: View {
        @State private var model = AppModel.demoSessions(
            project: ProjectListResult.Project.samples[1], instructions: .absent
        )
        @State private var isHolding = true

        var body: some View {
            Group {
                if isHolding {
                    HoldingView(purpose: .reconnecting) { isHolding = false }
                } else {
                    SessionsView(model: model, project: ProjectListResult.Project.samples[1])
                }
            }
        }
    }
#endif
