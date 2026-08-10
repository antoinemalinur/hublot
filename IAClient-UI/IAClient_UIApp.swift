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
                case .conversation:
                    ConversationView.screenTestDemo
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
