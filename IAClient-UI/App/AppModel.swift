//
//  AppModel.swift
//  Hublot
//
//  La racine : l'écran affiché, et une liaison qu'on ne redemande jamais de
//  rétablir à la main.
//
//  Le parcours suit la façon dont on travaille : un projet, puis une de ses
//  conversations, puis le fil. Les deux premiers écrans sont lus sur le VPS à
//  chaque affichage — rien n'est mémorisé côté app, donc rien ne se périme.
//

import Foundation
import Observation
import OSLog
import SwiftUI

@MainActor
@Observable
final class AppModel {

    enum Screen: Equatable {
        /// Au démarrage, quand on a déjà de quoi se connecter.
        ///
        /// Sans cet état, l'écran de départ était le **formulaire de
        /// connexion** : une page de réglages déjà remplie, affichée à chaque
        /// ouverture pendant que la liaison s'établissait, comme si elle
        /// attendait qu'on retape quelque chose. Elle ne doit apparaître que
        /// lorsqu'il y a vraiment un réglage à corriger.
        case launching
        case connection
        case projects
        case sessions(ProjectListResult.Project)
        case conversation

        /// Vrai tant qu'aucun contenu du VPS n'est encore affiché.
        var isEntry: Bool { self == .launching || self == .connection }
    }

    // MARK: Réglages
    //
    // L'adresse est un réglage ordinaire ; le jeton donne accès à un shell sur
    // le VPS et ne vit que dans le trousseau.

    var serverURL: String {
        didSet { environment.writeServerURL(serverURL) }
    }

    var token: String {
        didSet { environment.writeToken(token) }
    }

    private static let repositoriesRoot = "/root/repos"
    private let environment: HublotEnvironment
    #if DEBUG
        private var isDemo = false
    #endif

    // MARK: État

    private(set) var screen: Screen = .connection
    private(set) var projects: [ProjectListResult.Project] = []
    private(set) var sessions: [SessionListResult.Summary] = []
    private(set) var failure: String?
    private(set) var isBusy = false
    private(set) var chat: ChatSession?

    /// Vrai pendant une reprise silencieuse : la barre le signale sans renvoyer
    /// vers l'écran de connexion.
    private(set) var isReconnecting = false

    private var connection: ACPConnection?
    private var capabilities: InitializeResult.AgentCapabilities?
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var openProject: ProjectListResult.Project?

    /// La conversation qu'on regarde, retenue **au-delà** de la liaison qui la
    /// porte.
    ///
    /// Une reprise détruit le fil — il tient un socket mort — mais l'écran reste
    /// sur `.conversation`. Sans ce souvenir, la vue n'avait plus rien à
    /// afficher : un écran blanc sans bouton ni retour, dont on ne sortait qu'en
    /// tuant l'application. C'était le symptôme visible ; la cause est que
    /// `teardown()` jette le fil sans que personne ne sache le reconstruire.
    private struct OpenConversation {
        var sessionId: String
        var cwd: String
        var title: String
    }
    private var openConversation: OpenConversation?

    /// Les derniers plafonds annoncés, quelle que soit la conversation.
    ///
    /// Ils décrivent la machine, pas un fil : les garder ici est la seule façon
    /// d'avoir une barre de statut dès l'ouverture. Le serveur les pousse avec
    /// `session/new`, mais **avant** d'en répondre l'identifiant — la
    /// notification arrivait donc quand aucun fil n'écoutait encore, et la barre
    /// restait vide jusqu'à la fin du premier tour.
    private(set) var lastStatus: SessionStatus?
    private var statusWatch: Task<Void, Never>?

    /// Les tours en cours sur le VPS, tous projets confondus.
    ///
    /// Sans eux, on n'apprenait qu'une conversation travaillait qu'en l'ouvrant.
    /// Une demande longue lancée avant de ranger le téléphone devenait
    /// invisible : rien, sur l'écran d'accueil, ne distinguait un projet au
    /// repos d'un projet en plein travail.
    private(set) var running: [RunningResult.Turn] = []

    /// Assez souvent pour que l'écran d'accueil dise la vérité, assez rare pour
    /// que ça ne pèse rien : la requête ne lit qu'un dictionnaire en mémoire.
    private static let runningInterval = Duration.seconds(3)

    func runningTurns(in project: ProjectListResult.Project) -> [RunningResult.Turn] {
        running.filter { $0.cwd == project.path }
    }

    func isRunning(_ sessionId: String) -> Bool {
        running.contains { $0.sessionId == sessionId }
    }

    /// Interroge le relais tant qu'un écran de liste est affiché. Les écrans de
    /// conversation n'en ont pas besoin : ils reçoivent déjà le battement du
    /// tour qu'ils portent.
    func watchRunning() async {
        // La tâche appartient à `.task` de la vue. Ainsi SwiftUI l'annule en
        // quittant la liste ; une tâche non structurée attendue ici survivait
        // au changement d'écran et continuait à interroger le relais derrière
        // la conversation.
        while !Task.isCancelled {
            await refreshRunning()
            do {
                try await environment.sleep(Self.runningInterval)
            } catch {
                return
            }
        }
    }

    private func refreshRunning() async {
        guard let connection else { return }
        // Une liste indisponible n'est pas une panne : on garde la précédente
        // plutôt que de faire clignoter les pastilles à chaque hoquet réseau.
        guard let result = try? await connection.call(
            "hublot/running", Empty(), as: RunningResult.self, timeout: .seconds(10)
        ) else { return }
        running = result.turns
    }

    private let log = Logger(subsystem: "hublot", category: "app")

    init(environment providedEnvironment: HublotEnvironment? = nil) {
        let environment = providedEnvironment ?? .live
        self.environment = environment
        serverURL = environment.readServerURL() ?? ""
        token = environment.readToken() ?? ""

        #if DEBUG
            if let seeded = UserDefaults.standard.string(forKey: "HublotToken"), !seeded.isEmpty {
                token = seeded
            }
        #endif

        // Une affectation dans `init` ne déclenche pas `didSet` : sans cette
        // écriture explicite, l'adresse et le jeton fournis au lancement
        // n'étaient jamais retenus.
        persist()

        // Le jeton est dans le trousseau : il n'y a rien à demander, donc rien
        // à montrer qui ressemble à une question.
        screen = isConfigured ? .launching : .connection
    }

    private func persist() {
        if !serverURL.isEmpty { environment.writeServerURL(serverURL) }
        if !token.isEmpty { environment.writeToken(token) }
    }

    var isConfigured: Bool { !serverURL.isEmpty && !token.isEmpty }

    #if DEBUG
        static func demo(
            projects: [ProjectListResult.Project], failure: String? = nil
        ) -> AppModel {
            let model = AppModel(environment: .ephemeral())
            model.isDemo = true
            model.projects = projects
            model.failure = failure
            if let active = projects.first(where: { $0.name == "office-chess" }) {
                model.running = [.init(
                    sessionId: "screen-running", cwd: active.path, engine: "claude",
                    phase: .tool, label: "pytest", elapsed: 134, quiet: 1
                )]
            }
            model.screen = .projects
            return model
        }

        static func demoSessions(
            project: ProjectListResult.Project,
            sessions: [SessionListResult.Summary]? = nil,
            failure: String? = nil
        ) -> AppModel {
            let model = AppModel(environment: .ephemeral())
            model.isDemo = true
            model.sessions = sessions ?? [
                .init(
                    sessionId: "screen-running", cwd: project.path,
                    title: "Valider les corrections d'interface", updatedAt: .now,
                    exchanges: 6
                ),
                .init(
                    sessionId: "screen-idle", cwd: project.path,
                    title: "Conversation terminée", updatedAt: .now.addingTimeInterval(-3_600),
                    exchanges: 2
                ),
            ]
            model.failure = failure
            model.running = [.init(
                sessionId: "screen-running", cwd: project.path, engine: "claude",
                phase: .tool, label: "/root/repos/office-chess/pytest", elapsed: 134, quiet: 1
            )]
            model.instructions = .init(
                path: "/root/repos/office-chess/CLAUDE.md",
                content: "# Instructions\n\nValider chaque changement avant livraison.",
                bytes: 58, updatedAt: model.environment.now()
            )
            model.screen = .sessions(project)
            return model
        }
    #endif

    // MARK: Connexion

    /// Établit la liaison. Appelée une fois au démarrage, puis plus jamais par
    /// l'utilisateur : les reprises se font seules.
    func connect() async {
        guard let url = URL(string: serverURL), url.scheme?.hasPrefix("ws") == true else {
            failure = TransportError.badURL(serverURL).localizedDescription
            screen = .connection
            return
        }

        isBusy = true
        defer { isBusy = false }
        await teardown()

        let connection = environment.makeConnection(url, token)
        self.connection = connection

        do {
            try await connection.start()
            await watchStatus(on: connection)
            let result = try await connection.call(
                "initialize", InitializeParams(), as: InitializeResult.self
            )
            capabilities = result.agentCapabilities
            reconnectAttempt = 0
            failure = nil
            isReconnecting = false
            Task { await environment.requestNotificationAuthorization() }

            await loadProjects()
            if screen.isEntry { screen = .projects }
            await restoreConversation()
        } catch {
            // Un jeton refusé demande une intervention ; tout le reste est une
            // panne passagère qu'on ne doit pas faire porter à l'utilisateur —
            // et surtout pas en lui remettant sous les yeux un formulaire dont
            // le contenu est parfaitement bon.
            if isRejected(error) {
                failure = "Jeton refusé par le serveur."
                screen = .connection
            } else {
                log.notice("connexion échouée : \(error.localizedDescription, privacy: .public)")
                scheduleReconnect()
            }
        }
    }

    /// Ouvre les réglages de liaison à la demande — l'issue de secours d'un
    /// démarrage qui n'aboutit pas. C'est le seul chemin qui montre ce
    /// formulaire sans qu'une erreur l'ait exigé.
    func showConnectionSettings() {
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
        screen = .connection
    }

    /// Surveille la liaison : les plafonds qu'elle pousse, et sa mort.
    ///
    /// Les plafonds valent pour toutes les conversations, d'où le fait de les
    /// retenir ici. La mort, elle, n'était surveillée **nulle part** : quand le
    /// socket tombait au milieu d'un tour — redémarrage du service, réseau qui
    /// s'absente, téléphone en veille — le fil restait affiché tel quel, un
    /// outil en cours pour toujours, et rien ne repartait avant un aller-retour
    /// par l'écran d'accueil. C'est l'unique raison pour laquelle une réponse
    /// « s'arrêtait d'écrire ».
    private func watchStatus(on connection: ACPConnection) async {
        let events = await connection.subscribe()
        statusWatch?.cancel()
        statusWatch = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                switch event {
                case .update(let notification):
                    guard case .usage(_, _, let pushed, _) = notification.update, let pushed
                    else { continue }
                    self?.lastStatus = pushed
                case .disconnected(let error):
                    self?.linkLost(error)
                    return
                default:
                    continue
                }
            }
        }
    }

    /// La liaison est tombée sans qu'on l'ait demandé : on reprend seul.
    ///
    /// Une coupure volontaire passe par `teardown()`, qui annule ce guetteur
    /// avant de fermer — on n'arrive donc ici que sur une mort subie.
    private func linkLost(_ error: Error?) {
        guard connection != nil, isConfigured else { return }
        log.notice("liaison tombée : \(error?.localizedDescription ?? "flux terminé", privacy: .public)")
        isReconnecting = true
        // Le serveur, lui, continue son tour et enregistrera la réponse : la
        // reprise la rejouera par `session/load`. Rien n'est perdu, à condition
        // de se rebrancher.
        scheduleReconnect()
    }

    /// Remet en place la conversation qu'on regardait avant la coupure.
    ///
    /// `session/load` rejoue tout l'historique, y compris ce que le moteur a
    /// écrit pendant qu'on n'écoutait plus : c'est ce qui rend une réponse
    /// interrompue par une coupure récupérable, au lieu d'être perdue.
    private func restoreConversation() async {
        guard case .conversation = screen, chat == nil,
            let open = openConversation, let connection
        else { return }

        guard let session = await prepare(
            sessionId: open.sessionId, cwd: open.cwd, title: open.title,
            setup: nil, isResuming: true
        ) else { return }
        do {
            let setup = try await connection.call(
                "session/load",
                LoadSessionParams(sessionId: open.sessionId, cwd: open.cwd),
                as: SessionSetup.self
            )
            session.apply(setup)
            await session.finishReplay()
            reveal(
                session, sessionId: open.sessionId, cwd: open.cwd, title: open.title
            )
        } catch {
            await session.disconnect()
            // On retombe sur la liste des conversations : un écran vide n'est
            // jamais une réponse acceptable à un échec.
            log.error("reprise du fil impossible : \(error.localizedDescription, privacy: .public)")
            closeConversation()
            failure = error.localizedDescription
        }
    }

    /// Coupe volontairement — le seul chemin qui ramène à l'écran de connexion.
    func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        openConversation = nil
        await teardown()
        screen = .connection
    }

    private func teardown() async {
        statusWatch?.cancel()
        statusWatch = nil
        await chat?.disconnect()
        chat = nil
        await connection?.stop()
        connection = nil
    }

    private func isRejected(_ error: Error) -> Bool {
        if let rpc = error as? RPCError { return rpc.code == -32000 }
        if case TransportError.closed(let code, _) = error { return code == 4401 }
        return false
    }

    /// Retente en espaçant, indéfiniment. On ne renvoie jamais l'utilisateur
    /// vers un formulaire qu'il a déjà rempli : l'adresse et le jeton sont
    /// bons, c'est le réseau ou le serveur qui manque à l'appel.
    private func scheduleReconnect() {
        guard reconnectTask == nil, isConfigured else { return }
        isReconnecting = true
        let delay = min(pow(2, Double(reconnectAttempt)), 30)
        reconnectAttempt += 1
        let sleep = environment.sleep
        reconnectTask = Task { [weak self] in
            try? await sleep(.seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            await self.connect()
        }
    }

    // MARK: Projets

    func loadProjects() async {
        guard let connection else { return }
        do {
            let result = try await connection.call(
                "hublot/projects", Empty(), as: ProjectListResult.self
            )
            // « Tous les dépôts » reste en tête quoi qu'il arrive : c'est une
            // portée, pas un projet, et la trier par date la faisait tomber en
            // bas de liste dès qu'elle n'avait pas encore servi. Le reste
            // s'ordonne par travail récent — l'ordre dans lequel on cherche.
            let scope = result.projects.filter { $0.path == Self.repositoriesRoot }
            let rest = result.projects
                .filter { $0.path != Self.repositoriesRoot }
                .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            projects = scope + rest
        } catch {
            log.error("projets illisibles : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Le `CLAUDE.md` du projet ouvert, `nil` s'il n'en a pas. Chargé en même
    /// temps que les conversations : le bouton ne doit apparaître que quand il
    /// y a quelque chose à lire.
    private(set) var instructions: InstructionsResult.Document?

    func open(_ project: ProjectListResult.Project) async {
        openProject = project
        sessions = []
        instructions = nil
        screen = .sessions(project)
        await loadSessions(for: project)
        await loadInstructions(for: project)
    }

    private func loadInstructions(for project: ProjectListResult.Project) async {
        guard let connection else { return }
        // Une absence n'est pas une erreur : beaucoup de dépôts n'en ont pas.
        instructions = try? await connection.call(
            "hublot/instructions", ListSessionsParams(cwd: project.path),
            as: InstructionsResult.self
        ).instructions
    }

    func createProject(named name: String) async {
        let safe = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\ ")).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        guard !safe.isEmpty else {
            failure = "Nom de projet invalide."
            return
        }
        // Le dossier naît avec la première conversation : c'est `session/new`
        // qui le crée côté serveur, borné à `/root/repos`.
        let project = ProjectListResult.Project(
            name: safe, path: "/root/repos/\(safe)", sessionCount: 0, updatedAt: environment.now()
        )
        openProject = project
        await startSession(in: project)
    }

    // MARK: Conversations

    func loadSessions(for project: ProjectListResult.Project) async {
        guard let connection else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await connection.call(
                "session/list", ListSessionsParams(cwd: project.path), as: SessionListResult.self
            )
            sessions = result.sessions
        } catch {
            sessions = []
            failure = error.localizedDescription
        }
    }

    /// Une conversation neuve sur ce projet.
    func startSession(in project: ProjectListResult.Project) async {
        guard let connection else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let setup = try await connection.call(
                "session/new", NewSessionParams(cwd: project.path), as: SessionSetup.self
            )
            guard let sessionId = setup.sessionId else {
                failure = "Le serveur n'a pas renvoyé d'identifiant de session."
                return
            }
            await present(
                sessionId: sessionId, cwd: project.path, title: project.name, setup: setup
            )
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Reprend une conversation, même vieille de plusieurs semaines.
    func resume(_ summary: SessionListResult.Summary) async {
        guard let connection, let cwd = summary.cwd else { return }
        isBusy = true
        defer { isBusy = false }

        // Le consommateur est ouvert AVANT la demande : l'agent rejoue
        // l'historique par `session/update` avant de répondre à `session/load`.
        // L'écran, lui, ne paraît qu'après la barrière de fin de rejeu.
        guard let session = await prepare(
            sessionId: summary.sessionId, cwd: cwd, title: summary.displayTitle,
            setup: nil, isResuming: true
        ) else { return }

        do {
            let setup = try await connection.call(
                "session/load",
                LoadSessionParams(sessionId: summary.sessionId, cwd: cwd),
                as: SessionSetup.self
            )
            session.apply(setup)
            await session.finishReplay()
            reveal(
                session, sessionId: summary.sessionId, cwd: cwd,
                title: summary.displayTitle
            )
        } catch {
            await session.disconnect()
            closeConversation()
            failure = "« \(summary.displayTitle) » : \(error.localizedDescription)"
        }
    }

    /// Supprime la conversation *et* son historique, sans corbeille.
    func delete(_ summary: SessionListResult.Summary) async {
        #if DEBUG
            if connection == nil, isDemo {
                withAnimation(.snappy(duration: 0.25)) {
                    sessions.removeAll { $0.sessionId == summary.sessionId }
                }
                return
            }
        #endif
        guard let connection, let cwd = summary.cwd else { return }
        do {
            try await connection.call(
                "session/delete",
                DeleteSessionParams(sessionId: summary.sessionId, cwd: cwd)
            )
            withAnimation(.snappy(duration: 0.25)) {
                sessions.removeAll { $0.sessionId == summary.sessionId }
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func present(
        sessionId: String, cwd: String, title: String, setup: SessionSetup?,
        isResuming: Bool = false
    ) async {
        guard let session = await prepare(
            sessionId: sessionId, cwd: cwd, title: title,
            setup: setup, isResuming: isResuming
        ) else { return }
        reveal(session, sessionId: sessionId, cwd: cwd, title: title)
    }

    /// Construit le consommateur avant `session/load`, mais ne le publie pas
    /// encore dans l'interface. Il peut ainsi assembler chaque notification
    /// sans exposer au lecteur le défilement du rejeu.
    private func prepare(
        sessionId: String, cwd: String, title: String, setup: SessionSetup?,
        isResuming: Bool
    ) async -> ChatSession? {
        guard let connection else { return nil }
        // L'abonnement est ouvert **avant** que le fil existe : entre les deux,
        // c'est son tampon qui retient ce qui arrive.
        let events = await connection.subscribe()
        let session = ChatSession(
            connection: connection, events: events, workingDirectory: cwd,
            sessionId: sessionId, title: title, isResuming: isResuming,
            status: lastStatus, environment: environment
        )
        session.apply(setup)
        return session
    }

    private func reveal(
        _ session: ChatSession, sessionId: String, cwd: String, title: String
    ) {
        closeChat()
        chat = session
        openConversation = .init(sessionId: sessionId, cwd: cwd, title: title)
        screen = .conversation
    }

    /// Arrête le fil sortant. Sans ça sa boucle de lecture survivait à l'écran :
    /// elle restait abonnée, et continuait de consommer des trames pour une
    /// conversation que plus personne ne regardait.
    private func closeChat() {
        guard let closing = chat else { return }
        chat = nil
        Task { await closing.disconnect() }
    }

    func closeConversation() {
        closeChat()
        // Quitter un fil est délibéré : une reprise ne doit pas le rouvrir
        // dans le dos de celui qui vient d'en sortir.
        openConversation = nil
        // On revient aux conversations du projet, pas aux projets : enchaîner
        // deux fils sur le même dépôt est le cas courant.
        if let project = openProject {
            screen = .sessions(project)
            Task { await loadSessions(for: project) }
        } else {
            screen = .projects
        }
    }

    func back() {
        switch screen {
        case .sessions:
            openProject = nil
            screen = .projects
            Task { await loadProjects() }
        case .conversation:
            closeConversation()
        default:
            break
        }
    }

    // MARK: Retour au premier plan

    /// Le socket meurt en silence pendant la veille. Au réveil on teste, et si
    /// c'est mort on reprend — sans rien demander.
    func handleForeground() async {
        guard isConfigured, screen != .connection else { return }
        // Le tout premier passage au premier plan tombe en même temps que la
        // connexion du lancement. Sans ce garde-fou, l'app ouvrirait deux
        // liaisons en parallèle à chaque démarrage.
        guard !isBusy else { return }

        // Une reprise déjà entamée pendant la veille : on ne la double pas, on
        // la précipite. Attendre son prochain essai — jusqu'à trente secondes —
        // laissait l'écran figé sur un fil mort juste au moment où l'on revient
        // le consulter.
        if isReconnecting || connection == nil {
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectAttempt = 0
            await connect()
            return
        }
        guard let connection else { return }
        do {
            // Une échéance courte : c'est un test de vie, pas un appel utile.
            // Trente secondes à fixer un écran qui ne répond pas, c'est ce
            // qu'on cherche justement à éviter.
            try await connection.call("hublot/projects", Empty(), timeout: .seconds(8))
            reconnectAttempt = 0
            isReconnecting = false
        } catch {
            log.notice("liaison perdue au réveil, reprise")
            reconnectAttempt = 0
            await connect()
        }
    }
}
