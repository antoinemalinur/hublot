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
                // `-HublotRadiographyDemo 1` rend la carte sans serveur : une
                // feature visuelle doit pouvoir être photographiée à chaque
                // changement, pas seulement lorsqu'un tour réel tombe juste.
                if UserDefaults.standard.bool(forKey: "HublotRadiographyDense") {
                    // La carte chargée : quatorze régions, conversation finie.
                    // C'est le cas qui se chevauchait et qui s'animait à tort.
                    RadiographyView.dense
                } else if UserDefaults.standard.bool(forKey: "HublotRadiographyDemo") {
                    RadiographyView.demo
                } else if UserDefaults.standard.bool(forKey: "HublotConversationDemo") {
                    // Fil déterministe et assez long pour exercer le chrome,
                    // le retour au direct, les groupes et la radiographie sans
                    // dépendre du VPS pendant les tests d'interface.
                    ConversationView.screenTestDemo
                } else if UserDefaults.standard.bool(forKey: "HublotSessionsDemo") {
                    let project = ProjectListResult.Project.samples[1]
                    SessionsView(model: .demoSessions(project: project), project: project)
                } else if UserDefaults.standard.bool(forKey: "HublotProjectsDemo") {
                    // `-HublotProjectsDemo 1` rend la liste des projets sans
                    // serveur. Même raison que ci-dessus : un écran qu'on ne
                    // peut photographier qu'en étant connecté au VPS n'est
                    // vérifié que lorsqu'on y pense.
                    ProjectsView(model: .demo(projects: ProjectListResult.Project.samples))
                } else {
                    RootView()
                }
            #else
                RootView()
            #endif
        }
    }
}

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
