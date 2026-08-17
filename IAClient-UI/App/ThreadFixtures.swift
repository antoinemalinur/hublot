//
//  ThreadFixtures.swift
//  Hublot
//
//  Les états déterministes du fil : ses blocs, son chrome, son composer, et les
//  deux écrans d'analyse qu'il ouvre.
//
//  Tous portent des données figées. Ce qu'ils vérifient est un rendu et un pli —
//  aucun aller-retour avec le relais n'y est en jeu, et un transport témoin
//  n'ajouterait qu'une source d'instabilité à des tests de géométrie.
//

#if DEBUG
    import SwiftUI
    import UIKit

    // MARK: - Blocs

    /// Un exemplaire de chaque bloc que le fil sait rendre, sur un seul écran.
    ///
    /// Aucun n'était couvert au-delà du groupe d'appels répétés : ni le pli d'un
    /// appel isolé, ni l'ouverture automatique d'un échec, ni le verdict qui
    /// remplace les boutons d'une permission. Ce sont des régressions visuelles
    /// et silencieuses — un pli qui ne s'ouvre plus ne casse rien, il cache.
    struct ThreadBlocksFixture: View {
        var body: some View {
            ConversationView(
                sessionTitle: "Tous les blocs", engine: .claude,
                turns: Self.turns, onBack: {},
                onDictate: { _ in nil }
            )
        }

        private static var turns: [Turn] {
            [
                .user(.init(
                    id: "avec-image",
                    text: "Voici la capture du plantage.",
                    images: [HublotFixtureImage.jpeg(side: 120)]
                )),
                .assistant(.init(
                    id: "prose",
                    markdown: "La pile vient de `ChatSession`. Je regarde le diff."
                )),
                .thought(.init(
                    id: "raisonnement",
                    markdown: "RAISONNEMENT VISIBLE — le tampon n'était pas vidé.",
                    duration: .seconds(3)
                )),
                // Deux natures différentes, donc deux lignes isolées : le
                // regroupement ne rassemble que des appels consécutifs de même
                // nature, et un appel seul n'a rien à replier.
                .toolCall(.init(
                    id: "diff", title: "ChatSession.swift", kind: .edit,
                    status: .completed,
                    location: "/root/repos/hublot/IAClient-UI/Domain/ChatSession.swift",
                    detail: "+1 −1",
                    content: [.diff(
                        id: "diff-1", path: "IAClient-UI/Domain/ChatSession.swift",
                        oldText: "let ancienne = 1\ncontexte inchangé\n",
                        newText: "let nouvelle = 2\ncontexte inchangé\n"
                    )]
                )),
                .toolCall(.init(
                    id: "echec", title: "pytest tests/", kind: .execute,
                    status: .failed, detail: "code 1",
                    content: [.terminal(
                        id: "sortie-1",
                        output: "SORTIE DU TERMINAL — 1 failed, 12 passed."
                    )]
                )),
                .assistant(.init(
                    id: "code",
                    markdown: """
                        Le correctif :

                        ```swift
                        stream.finish()
                        ```
                        """
                )),
                .permission(.init(
                    id: "en-attente", toolTitle: "rm -rf build", kind: .execute,
                    detail: "rm -rf /root/repos/hublot/build",
                    options: [
                        .init(id: "allow", name: "Autoriser une fois", kind: .allowOnce),
                        .init(id: "reject", name: "Refuser", kind: .rejectOnce),
                    ]
                )),
                .permission(.init(
                    id: "deja-tranchee", toolTitle: "git push", kind: .execute,
                    detail: "git push origin main",
                    options: [
                        .init(id: "allow", name: "Toujours autoriser", kind: .allowAlways),
                        .init(id: "reject", name: "Refuser", kind: .rejectOnce),
                    ],
                    chosen: "allow"
                )),
            ]
        }
    }

    /// Une image réelle, décodable, fabriquée à la volée.
    ///
    /// Un `Data` arbitraire ne conviendrait pas : `AttachedImage` retomberait sur
    /// son rectangle de secours, et le test ne verrait jamais la vignette qu'il
    /// prétend vérifier.
    enum HublotFixtureImage {
        static func jpeg(side: CGFloat) -> Data {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let size = CGSize(width: side, height: side)
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor(red: 0.85, green: 0.42, blue: 0.16, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor.white.setFill()
                context.fill(CGRect(x: side / 4, y: side / 4, width: side / 2, height: side / 2))
            }
            return image.jpegData(compressionQuality: 0.8) ?? Data()
        }
    }

    /// Un fil qui grandit sous les yeux du lecteur.
    ///
    /// Le tour supplémentaire n'arrive qu'après un délai franc : le geste à
    /// vérifier est ce que fait le **défilement** quand une réponse tombe, et il
    /// faut avoir le temps de se placer avant qu'elle ne tombe.
    struct ThreadGrowingFixture: View {
        @State private var turns: [Turn] = Self.initialTurns
        @State private var delivered = false

        /// Quatre secondes : de quoi voir le fil au repos avant que le tour ne
        /// tombe. Le test qui doit d'abord défiler vers le haut se donne plus de
        /// temps avec `-HublotGrowingDelay` — remonter un fil de dix tours prend
        /// plusieurs balayages, et le tour ne doit pas arriver pendant.
        private static var arrivesAfter: Duration {
            .seconds(HublotLaunchDelay.seconds("-HublotGrowingDelay", fallback: 4))
        }

        /// Le tour attend qu'on le demande, au lieu de tomber sur une minuterie.
        ///
        /// Un test qui doit d'abord se placer dans le fil ne sait pas combien de
        /// temps ses balayages prendront : deux secondes sur une machine au
        /// repos, près de vingt sous quatre simulateurs. Un délai fixe doit donc
        /// couvrir le pire cas, et fait payer ce pire cas à chaque exécution —
        /// quarante-quatre secondes d'attente aveugle, mesurées le 16 août 2026
        /// comme 7 % du travail d'interface de toute la suite. Le raccourcir
        /// rendrait la validité du test dépendante de la charge. Le déclencheur
        /// supprime la course : le tour tombe quand le test est prêt.
        private static var waitsForDemand: Bool {
            ProcessInfo.processInfo.arguments.contains("-HublotGrowingOnDemand")
        }

        var body: some View {
            ConversationView(
                sessionTitle: "Fil qui grandit", engine: .claude,
                turns: turns, onBack: {},
                onDictate: { _ in nil }
            )
            .task {
                guard !Self.waitsForDemand else { return }
                try? await Task.sleep(for: Self.arrivesAfter)
                deliver()
            }
            .overlay(alignment: .topLeading) {
                // Le bouton s'efface en livrant : sa disparition est la seule
                // preuve observable que le tour est tombé, puisque le tour lui,
                // s'il se comporte bien, naît hors du champ.
                if Self.waitsForDemand, !delivered {
                    Button("Faire tomber le tour", action: deliver)
                        .accessibilityIdentifier("growing-trigger")
                        .font(.caption2)
                        .padding(4)
                        .background(.thinMaterial, in: .rect(cornerRadius: 4))
                        .padding(.leading, 4)
                }
            }
        }

        private func deliver() {
            turns.append(.assistant(.init(
                id: "tour-onze",
                markdown: "TOUR ONZE — arrivé après l'affichage."
            )))
            delivered = true
        }

        private static var initialTurns: [Turn] {
            var rows: [Turn] = []
            for index in 1...10 {
                rows.append(.user(.init(
                    id: "demande-\(index)", text: "Demande \(index) du fil témoin."
                )))
                rows.append(.assistant(.init(
                    id: "reponse-\(index)",
                    markdown: String(repeating: "Réponse \(index). ", count: 12)
                )))
            }
            rows.append(.assistant(.init(
                id: "tour-dix",
                markdown: "TOUR DIX — dernier tour avant l'arrivée."
            )))
            return rows
        }
    }

    // MARK: - Chrome

    /// Les états du chrome haut, un par écran. Ils ne se distinguent que par ce
    /// qui les rend : un plan, un silence, une liaison qui se refait, ou rien du
    /// tout.
    struct ChromeFixture: View {
        enum State {
            case plan
            case lost
            case quiet
            case reconnecting
            case silent
        }

        let state: State

        var body: some View {
            ConversationView(
                sessionTitle: "Suivre la machine", engine: .claude,
                plan: state == .plan ? Self.plan : [],
                turns: [.assistant(.init(id: "unique", markdown: "Le moteur travaille."))],
                onBack: {},
                status: state == .silent ? nil : Self.status,
                contextPercent: state == .silent ? nil : 42,
                activity: activity,
                activityAt: activityAt,
                isWorking: state != .silent,
                isReconnecting: state == .reconnecting,
                onDictate: { _ in nil }
            )
        }

        /// Quatre jalons, deux franchis : la capsule doit annoncer « 2/4 » et
        /// les déplier au toucher.
        private static var plan: [PlanEntry] {
            [
                .init(id: "p1", content: "Relever l'inventaire des gestes", status: .completed),
                .init(id: "p2", content: "Écrire les états témoins", status: .completed),
                .init(id: "p3", content: "Écrire les tests d'interface", status: .inProgress),
                .init(id: "p4", content: "Vérifier chaque test par mutation", status: .pending),
            ]
        }

        private static var status: SessionStatus {
            SessionStatus(
                model: "Opus", effort: "high", engine: "claude",
                limits: [
                    "five_hour": .init(percent: 17, resetsAt: .now.addingTimeInterval(14_400))
                ]
            )
        }

        private var activity: Activity? {
            switch state {
            case .silent, .reconnecting:
                return nil
            case .quiet:
                // Le moteur n'a rien émis depuis une minute, mais le relais bat
                // toujours : c'est un silence du moteur, pas une liaison morte.
                return .init(
                    running: true, phase: .tool, label: "pytest",
                    engine: "claude", elapsed: 180, quiet: 60
                )
            case .lost, .plan:
                return .init(
                    running: true, phase: .tool, label: "pytest",
                    engine: "claude", elapsed: 42, quiet: 1
                )
            }
        }

        /// Le dernier battement reçu. Vingt-cinq secondes en arrière, c'est le
        /// relais lui-même qui s'est tu — il bat toutes les quatre secondes.
        private var activityAt: Date? {
            switch state {
            case .silent, .reconnecting: nil
            case .lost: .now.addingTimeInterval(-25)
            case .quiet, .plan: .now
            }
        }
    }

    // MARK: - Composer

    /// Une pièce jointe déjà choisie. Le sélecteur système qui y mène n'est pas
    /// pilotable ; ce que le composer en fait ensuite — la vignette, son poids,
    /// la croix qui la retire — l'est entièrement.
    struct ComposerAttachmentFixture: View {
        var body: some View {
            var view = ConversationView(
                sessionTitle: "Pièce jointe", engine: .claude,
                turns: [.assistant(.init(id: "unique", markdown: "Envoyez la capture."))],
                onBack: {},
                onDictate: { _ in nil }
            )
            view.debugAttachments = [Attachment(jpeg: HublotFixtureImage.jpeg(side: 320))]
            return view
        }
    }

    /// Micro refusé. L'autorisation se règle hors de l'app, mais l'invite qui y
    /// renvoie est un texte de cette app — et rien ne le vérifiait.
    struct ComposerRefusedMicFixture: View {
        var body: some View {
            var view = ConversationView(
                sessionTitle: "Micro refusé", engine: .claude,
                turns: [.assistant(.init(id: "unique", markdown: "Dictez votre demande."))],
                onBack: {},
                onDictate: { _ in nil }
            )
            view.debugDictationPhase = .refused
            return view
        }
    }

    // MARK: - Écrans d'analyse

    extension ContextTideView {
        /// Un fil sans la moindre mesure. L'écran doit le dire, pas afficher une
        /// cuve vide.
        static var emptyDemo: ContextTideView {
            ContextTideView(projectName: "Office Chess", history: [], isLive: false)
        }

        /// Les mêmes mesures que la marée témoin, sur une conversation
        /// **terminée** : trois mots séparent « direct » de « terminé », et le
        /// retour en arrière ne s'appelle plus pareil.
        static var finishedDemo: ContextTideView {
            var view = demo
            view.isLive = false
            return view
        }
    }

    extension RadiographyView {
        /// Une conversation sans le moindre outil : la carte n'a rien à
        /// dessiner, et doit l'annoncer plutôt que de rester noire.
        static var emptyDemo: RadiographyView {
            RadiographyView(
                projectName: "Hublot",
                turns: [
                    .user(.init(id: "question", text: "Résume le dépôt.")),
                    .assistant(.init(id: "reponse", markdown: "Aucun outil n'a servi.")),
                ],
                isLive: false
            )
        }
    }
#endif
