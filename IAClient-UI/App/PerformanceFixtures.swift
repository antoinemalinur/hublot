//
//  PerformanceFixtures.swift
//  Hublot
//
//  Les deux reproductions qui ne peuvent pas être des données figées : leur
//  sujet est précisément le travail effectué pendant que l'utilisateur agit.
//  Elles traversent ACPConnection, ChatSession et AppModel comme la production.
//

#if DEBUG
    import Combine
    import Foundation
    import Observation
    import SwiftUI

    // MARK: - Rafale de streaming

    struct StreamingPressureFixture: View {
        @State private var model = StreamingPressureFixtureModel()

        var body: some View {
            Group {
                if let chat = model.chat {
                    ZStack(alignment: .topTrailing) {
                        ConversationView(
                            sessionTitle: "Rafale en direct",
                            engine: chat.engine,
                            turns: chat.turns,
                            documentRevision: chat.documentRevision,
                            machineState: chat.machine,
                            onSend: { _, _ in },
                            onBack: {},
                            activity: chat.activity,
                            activityAt: chat.activityAt,
                            isWorking: chat.isWorking,
                            onDictate: { _ in nil }
                        )

                        if model.isReady && !model.isRunning && !model.isComplete {
                            Text("Rafale prête")
                                .accessibilityIdentifier("streaming-pressure-ready")
                        } else if model.isRunning {
                            Text("Rafale en cours")
                                .accessibilityIdentifier("streaming-pressure-running")
                        } else if model.isComplete {
                            Text("Rafale complète · \(model.visibleRevisions) révisions")
                                .font(.hublotMeta)
                                .foregroundStyle(Hublot.prose)
                                .padding(.horizontal, Hublot.unit)
                                .padding(.vertical, Hublot.unit * 0.5)
                                .background(Hublot.surface, in: .capsule)
                                .padding(.top, Hublot.unit)
                                .padding(.trailing, Hublot.unit)
                                .accessibilityIdentifier("streaming-pressure-complete")
                        }
                    }
                } else {
                    HoldingView(purpose: .launching) {}
                }
            }
            .task { await model.start() }
            // Le clavier est le déclencheur déterministe de la reproduction :
            // le premier caractère est ainsi saisi pendant la rafale, quelle
            // que soit la charge imposée à XCTest par les autres workers.
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardDidShowNotification
            )) { _ in
                model.beginBurst()
            }
        }
    }

    @MainActor
    @Observable
    private final class StreamingPressureFixtureModel {
        private static let sessionID = "streaming-pressure"

        private let transport: StreamingPressureTransport
        private let connection: ACPConnection
        private var started = false
        private var baselineRevision = 0

        private(set) var chat: ChatSession?
        private(set) var isReady = false
        private(set) var isRunning = false
        private(set) var isComplete = false
        private(set) var visibleRevisions = 0

        init() {
            let transport = StreamingPressureTransport()
            self.transport = transport
            connection = ACPConnection(transport: transport)
        }

        func start() async {
            guard !started else { return }
            started = true
            do {
                try await connection.start()
                let chat = ChatSession(
                    connection: connection, events: await connection.subscribe(),
                    workingDirectory: "/root/repos/hublot", sessionId: Self.sessionID,
                    title: "Rafale en direct"
                )
                self.chat = chat

                // Un vrai historique, assemblé par le même chemin que le VPS.
                // Il donne du poids au document avant que le clavier soit testé.
                for index in 0..<40 {
                    await transport.user(
                        session: Self.sessionID,
                        text: "Demande historique \(index)."
                    )
                    await transport.message(
                        session: Self.sessionID, id: "historique-\(index)",
                        text: "Réponse historique \(index).\n\n"
                    )
                }
                await transport.usage(session: Self.sessionID)
                try? await Task.sleep(for: .milliseconds(80))
                baselineRevision = chat.documentRevision
                isReady = true
            } catch {
                isComplete = false
            }
        }

        func beginBurst() {
            guard isReady, !isRunning, !isComplete else { return }
            isRunning = true
            Task { await runBurst() }
        }

        private func runBurst() async {
            guard let chat else { return }
            await transport.activity(session: Self.sessionID, running: true)
            for _ in 0..<40 {
                for _ in 0..<25 {
                    await transport.message(
                        session: Self.sessionID, id: "pression", text: "x"
                    )
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            // Les deux événements sont des barrières : le texte doit être
            // publié avant la mesure, puis le curseur arrêté avant le bilan.
            await transport.usage(session: Self.sessionID)
            await transport.activity(session: Self.sessionID, running: false)

            for _ in 0..<500 {
                let count = chat.turns.compactMap {
                    if case .assistant(let turn) = $0, turn.id == "pression" {
                        return turn.markdown.count
                    }
                    return nil
                }.first
                if count == 1_000, !chat.isWorking { break }
                try? await Task.sleep(for: .milliseconds(2))
            }

            visibleRevisions = chat.documentRevision - baselineRevision
            isComplete = chat.turns.contains {
                if case .assistant(let turn) = $0, turn.id == "pression" {
                    return turn.markdown == String(repeating: "x", count: 1_000)
                        && !turn.isStreaming
                }
                return false
            }
            isRunning = false
        }
    }

    private actor StreamingPressureTransport: ACPTransport {
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
            emit(["jsonrpc": "2.0", "id": id, "result": [:]])
        }

        func user(session: String, text: String) {
            notify(session: session, update: [
                "sessionUpdate": "user_message_chunk",
                "content": ["type": "text", "text": text],
            ])
        }

        func message(session: String, id: String, text: String) {
            notify(session: session, update: [
                "sessionUpdate": "agent_message_chunk", "messageId": id,
                "content": ["type": "text", "text": text],
            ])
        }

        func usage(session: String) {
            notify(session: session, update: [
                "sessionUpdate": "usage_update", "used": 10, "size": 100,
            ])
        }

        func activity(session: String, running: Bool) {
            notify(session: session, update: [
                "sessionUpdate": "hublot_activity", "running": running,
                "phase": running ? "writing" : "done", "elapsed": 1, "quiet": 0,
                "stopReason": running ? NSNull() : "end_turn",
            ])
        }

        private func notify(session: String, update: [String: Any]) {
            emit([
                "jsonrpc": "2.0", "method": "session/update",
                "params": ["sessionId": session, "update": update],
            ])
        }

        private func emit(_ object: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            continuation.yield(data)
        }
    }

    // MARK: - Entrée dans un projet sous réseau lent

    struct ProjectLoadingFixture: View {
        @State private var model: AppModel

        init() {
            let transport = ProjectLoadingTransport()
            var environment = HublotEnvironment.ephemeral(
                serverURL: "ws://127.0.0.1:8340", token: "ui-test",
                makeConnection: { _, _ in ACPConnection(transport: transport) }
            )
            environment.sleep = { duration in try await Task.sleep(for: duration) }
            _model = State(initialValue: AppModel(environment: environment))
        }

        var body: some View {
            Group {
                switch model.screen {
                case .projects:
                    ProjectsView(model: model)
                case .sessions(let project):
                    SessionsView(model: model, project: project)
                case .conversation:
                    if let chat = model.chat {
                        ConversationView(
                            sessionTitle: chat.title, engine: chat.engine,
                            turns: chat.turns,
                            documentRevision: chat.documentRevision,
                            machineState: chat.machine,
                            onBack: { model.closeConversation() }, onDictate: { _ in nil }
                        )
                    }
                default:
                    HoldingView(purpose: .launching) {}
                }
            }
            .task { await model.connect() }
        }
    }

    private actor ProjectLoadingTransport: ACPTransport {
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
                    "agentCapabilities": ["loadSession": true,
                                          "sessionCapabilities": ["list": [:]]],
                ])
            case "hublot/projects":
                reply(id, ["projects": [[
                    "name": "hublot", "path": "/root/repos/hublot",
                    "sessionCount": 2, "updatedAt": "2026-08-15T12:00:00.000Z",
                ]]])
            case "session/list":
                try? await Task.sleep(for: .seconds(3))
                reply(id, ["sessions": [[
                    "sessionId": "charge", "cwd": "/root/repos/hublot",
                    "title": "Conversation chargée", "exchanges": 2,
                ]]])
            case "hublot/instructions":
                try? await Task.sleep(for: .seconds(3))
                reply(id, ["instructions": NSNull()])
            case "hublot/running":
                reply(id, ["turns": []])
            case "session/new":
                reply(id, ["sessionId": "nouveau", "configOptions": []])
            default:
                reply(id, [:])
            }
        }

        private func reply(_ id: Int, _ result: [String: Any]) {
            emit(["jsonrpc": "2.0", "id": id, "result": result])
        }

        private func emit(_ object: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            continuation.yield(data)
        }
    }
#endif
