//
//  IAClient_UIApp.swift
//  Hublot
//
//  Created by Antoine Malinur on 2026-08-05.
//

import SwiftUI

@main
struct IAClient_UIApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
                switch HublotUITestScenario.current {
                case .radiographyDense:
                    RadiographyView.dense
                case .radiography:
                    RadiographyView.demo
                case .contextTide:
                    if ProcessInfo.processInfo.arguments.contains("-HublotSnapshotMode") {
                        ContextTideView.snapshotDemo
                    } else {
                        ContextTideView.demo
                    }
                case .codexQuota:
                    ConversationView.codexQuotaDemo
                case .activeEngineLock:
                    ConversationView.activeEngineLockDemo
                case .conversation:
                    ConversationView.screenTestDemo
                case .concurrentConversations:
                    ConcurrentConversationsFixture()
                case .sessions, .sessionsInstructions:
                    let project = ProjectListResult.Project.samples[1]
                    SessionsScreenFixture(
                        project: project,
                        initiallyShowsInstructions: HublotUITestScenario.current == .sessionsInstructions
                    )
                case .sessionsEmpty:
                    let project = ProjectListResult.Project.samples[1]
                    SessionsScreenFixture(project: project, sessions: [])
                case .sessionsError:
                    let project = ProjectListResult.Project.samples[1]
                    SessionsScreenFixture(
                        project: project, sessions: [], failure: "Historique indisponible."
                    )
                case .projects:
                    ProjectsScreenFixture(projects: ProjectListResult.Project.samples)
                case .projectsPromptAge:
                    ProjectsScreenFixture(projects: [
                        .init(
                            name: "dernier-prompt", path: "/root/repos/dernier-prompt",
                            sessionCount: 3, updatedAt: .now.addingTimeInterval(-3_600)
                        ),
                    ])
                case .projectsEmpty:
                    ProjectsScreenFixture(projects: [])
                case .projectsError:
                    ProjectsScreenFixture(
                        projects: [], failure: "Serveur temporairement indisponible."
                    )
                case .connection:
                    ConnectionScreenFixture()
                case nil:
                    RootView()
                }
            #else
                RootView()
            #endif
        }
    }
}

#if DEBUG
    /// Les ecrans temoins doivent posseder leur modele comme `RootView` le fait.
    /// Construire le modele dans `body` effacait une moitie du formulaire des
    /// que la premiere saisie invalidait la vue.
    private struct ConnectionScreenFixture: View {
        @State private var model = AppModel(environment: .ephemeral())

        var body: some View { ConnectionView(model: model) }
    }

    private struct ProjectsScreenFixture: View {
        @State private var model: AppModel

        init(projects: [ProjectListResult.Project], failure: String? = nil) {
            _model = State(initialValue: .demo(projects: projects, failure: failure))
        }

        var body: some View { ProjectsView(model: model) }
    }

    private struct SessionsScreenFixture: View {
        let project: ProjectListResult.Project
        let initiallyShowsInstructions: Bool
        @State private var model: AppModel

        init(
            project: ProjectListResult.Project,
            sessions: [SessionListResult.Summary]? = nil,
            failure: String? = nil,
            initiallyShowsInstructions: Bool = false
        ) {
            self.project = project
            self.initiallyShowsInstructions = initiallyShowsInstructions
            _model = State(initialValue: .demoSessions(
                project: project, sessions: sessions, failure: failure
            ))
        }

        var body: some View {
            SessionsView(
                model: model, project: project,
                initiallyShowsInstructions: initiallyShowsInstructions
            )
        }
    }

    /// Le vrai parcours à deux fils, alimenté par un relais déterministe.
    /// Les deux `session/prompt` restent volontairement sans réponse : revenir
    /// à la liste pendant qu'ils travaillent est précisément le geste qui a
    /// fait disparaître la seconde conversation sur l'iPhone.
    private struct ConcurrentConversationsFixture: View {
        @State private var model: AppModel

        init() {
            let transport = ConcurrentConversationsTransport()
            var environment = HublotEnvironment.ephemeral(
                serverURL: "ws://127.0.0.1:8325", token: "ui-test",
                makeConnection: { _, _ in ACPConnection(transport: transport) }
            )
            environment.sleep = { duration in try await Task.sleep(for: duration) }
            _model = State(initialValue: AppModel(environment: environment))
        }

        var body: some View {
            Group {
                switch model.screen {
                case .sessions(let project):
                    SessionsView(model: model, project: project)
                case .conversation:
                    if let chat = model.chat {
                        ConversationView(
                            sessionTitle: chat.title,
                            engine: chat.engine,
                            plan: chat.plan,
                            turns: chat.turns,
                            onSend: { text, images in
                                Task { await chat.send(text, attachments: images) }
                            },
                            onBack: { model.closeConversation() },
                            configOptions: chat.configOptions,
                            status: chat.metrics,
                            contextPercent: chat.contextPercent,
                            contextHistory: chat.contextHistory,
                            onChoose: { option, value in
                                Task { await chat.choose(option, value: value) }
                            },
                            activity: chat.activity,
                            activityAt: chat.activityAt,
                            isWorking: chat.isWorking,
                            isReconnecting: false,
                            onStop: { Task { await chat.cancel() } },
                            onDictate: { _ in nil }
                        )
                    }
                default:
                    HoldingView(purpose: .launching) {}
                }
            }
            .task {
                await model.connect()
                guard let project = model.projects.first(where: { $0.name == "hublot" })
                else { return }
                await model.open(project)
            }
        }
    }

    private actor ConcurrentConversationsTransport: ACPTransport {
        private let stream: AsyncThrowingStream<Data, Error>
        private let continuation: AsyncThrowingStream<Data, Error>.Continuation
        private var nextSession = 0
        private var prompts: [String: String] = [:]

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
            let params = request["params"] as? [String: Any] ?? [:]

            switch method {
            case "session/new":
                nextSession += 1
                reply(id, [
                    "sessionId": "ui-conversation-\(nextSession)",
                    "configOptions": [],
                ])
            case "session/prompt":
                guard let sessionId = params["sessionId"] as? String else { return }
                let blocks = params["prompt"] as? [[String: Any]] ?? []
                let text = blocks.compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
                prompts[sessionId] = text
                notify(sessionId, [
                    "sessionUpdate": "tool_call",
                    "toolCallId": "registered-\(sessionId)",
                    "title": "Tour enregistré sur le serveur",
                    "kind": "think",
                    "status": "in_progress",
                ])
                // Pas de réponse RPC : le tour reste en cours.
            case "session/list":
                let sessions = prompts.sorted { $0.key < $1.key }.map { sessionId, text in
                    [
                        "sessionId": sessionId,
                        "cwd": "/root/repos/hublot",
                        "title": text,
                        "updatedAt": "2026-08-10T19:23:00.000Z",
                        "exchanges": 1,
                    ] as [String: Any]
                }
                reply(id, ["sessions": sessions])
            case "hublot/running":
                let turns = prompts.keys.sorted().map { sessionId in
                    [
                        "sessionId": sessionId,
                        "cwd": "/root/repos/hublot",
                        "engine": "codex",
                        "phase": "thinking",
                        "label": "validation",
                        "elapsed": 12,
                        "quiet": 1,
                    ] as [String: Any]
                }
                reply(id, ["turns": turns])
            case "initialize":
                reply(id, [
                    "protocolVersion": 1,
                    "agentCapabilities": [
                        "loadSession": true,
                        "sessionCapabilities": ["list": [:]],
                    ],
                ])
            case "hublot/projects":
                reply(id, ["projects": [[
                    "name": "hublot",
                    "path": "/root/repos/hublot",
                    "sessionCount": prompts.count,
                    "updatedAt": "2026-08-10T19:23:00.000Z",
                ]]])
            case "hublot/instructions":
                reply(id, ["instructions": NSNull()])
            default:
                reply(id, [:])
            }
        }

        private func reply(_ id: Int, _ result: [String: Any]) {
            emit(["jsonrpc": "2.0", "id": id, "result": result])
        }

        private func notify(_ sessionId: String, _ update: [String: Any]) {
            emit([
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": ["sessionId": sessionId, "update": update],
            ])
        }

        private func emit(_ object: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            continuation.yield(data)
        }
    }
#endif

/// La racine : connexion → projets → conversations → fil.
///
/// La connexion n'est demandée qu'une fois. Ensuite l'app se rebranche seule —
/// au lancement, et au retour au premier plan après une veille.
struct RootView: View {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
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
                        sessionTitle: chat.title,
                        engine: chat.engine,
                        plan: chat.plan,
                        turns: chat.turns,
                        onSend: { text, images in
                            Task { await chat.send(text, attachments: images) }
                        },
                        onBack: { model.closeConversation() },
                        configOptions: chat.configOptions,
                        status: chat.metrics,
                        contextPercent: chat.contextPercent,
                        contextHistory: chat.contextHistory,
                        onChoose: { option, value in
                            Task { await chat.choose(option, value: value) }
                        },
                        activity: chat.activity,
                        activityAt: chat.activityAt,
                        isWorking: chat.isWorking,
                        isReconnecting: model.isReconnecting,
                        onStop: { Task { await chat.cancel() } },
                        onDictate: { audio in try? await chat.transcribe(audio) }
                    )
                } else {
                    // Le fil peut disparaître sous l'écran : une reprise de
                    // liaison le détruit avant de le reconstruire. Pendant ce
                    // battement, il faut montrer quelque chose — l'écran vide
                    // qui tenait lieu de réponse ici ne laissait qu'une issue,
                    // tuer l'application.
                    HoldingView(purpose: .reconnecting) { model.closeConversation() }
                }
            }
        }
        .task {
            // Le jeton est déjà dans le trousseau : rouvrir l'app ne devrait
            // ni obliger à retaper sur « Se connecter », ni même montrer le
            // formulaire qui porte ce bouton.
            guard model.isConfigured, model.screen == .launching else { return }
            await model.connect()

            #if DEBUG
                await runScenario(on: model)
            #endif
        }

        .onChange(of: scenePhase) { _, phase in
            // Le socket meurt en silence pendant la veille : c'est au retour au
            // premier plan qu'on s'en aperçoit, pas avant.
            guard phase == .active else { return }
            Task { await model.handleForeground() }
        }
    }

    #if DEBUG
        /// Le parcours joué au lancement, pour qu'un écran soit vérifiable en
        /// capture sans qu'on ait à le viser du doigt.
        ///
        ///     -HublotProject <nom>       ouvre les conversations d'un dépôt
        ///     -HublotOpening "…"         ouvre un fil et pose la question
        ///     -HublotSecondSession 1     en ouvre un premier et le quitte
        ///                                avant — c'est la condition qui a
        ///                                fait disparaître une trame sur deux
        ///
        /// Le troisième mérite son existence : le bug le plus coûteux du
        /// projet ne se voyait qu'à la **deuxième** conversation ouverte, et
        /// aucune vérification ne l'atteignait puisqu'elles n'en ouvraient
        /// jamais qu'une.
        private func runScenario(on model: AppModel) async {
            let defaults = UserDefaults.standard
            if let name = defaults.string(forKey: "HublotProject"), !name.isEmpty,
                let project = model.projects.first(where: { $0.name == name })
            {
                await model.open(project)
            }

            guard let opening = defaults.string(forKey: "HublotOpening"), !opening.isEmpty
            else { return }

            func target() -> ProjectListResult.Project? {
                if case .sessions(let project) = model.screen { return project }
                return model.projects.first
            }

            if defaults.bool(forKey: "HublotSecondSession"), let project = target() {
                await model.startSession(in: project)
                model.closeConversation()
                try? await Task.sleep(for: .seconds(1))
            }

            if model.chat == nil, let project = target() {
                await model.startSession(in: project)
            }
            if let chat = model.chat { await chat.send(opening) }
        }
    #endif
}
