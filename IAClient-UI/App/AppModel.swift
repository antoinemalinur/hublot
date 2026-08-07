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
        case connection
        case projects
        case sessions(ProjectListResult.Project)
        case conversation
    }

    // MARK: Réglages
    //
    // L'adresse est un réglage ordinaire ; le jeton donne accès à un shell sur
    // le VPS et ne vit que dans le trousseau.

    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Self.urlKey) }
    }

    var token: String {
        didSet { Keychain.save(token, for: Self.tokenAccount) }
    }

    private static let urlKey = "hublot.serverURL"
    private static let tokenAccount = "acp-token"
    private static let repositoriesRoot = "/root/repos"

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

    /// Les derniers plafonds annoncés, quelle que soit la conversation.
    ///
    /// Ils décrivent la machine, pas un fil : les garder ici est la seule façon
    /// d'avoir une barre de statut dès l'ouverture. Le serveur les pousse avec
    /// `session/new`, mais **avant** d'en répondre l'identifiant — la
    /// notification arrivait donc quand aucun fil n'écoutait encore, et la barre
    /// restait vide jusqu'à la fin du premier tour.
    private(set) var lastStatus: SessionStatus?
    private var statusWatch: Task<Void, Never>?

    private let log = Logger(subsystem: "hublot", category: "app")

    init() {
        serverURL = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        token = Keychain.read(Self.tokenAccount) ?? ""

        #if DEBUG
            if let seeded = UserDefaults.standard.string(forKey: "HublotToken"), !seeded.isEmpty {
                token = seeded
            }
        #endif

        // Une affectation dans `init` ne déclenche pas `didSet` : sans cette
        // écriture explicite, l'adresse et le jeton fournis au lancement
        // n'étaient jamais retenus.
        persist()
    }

    private func persist() {
        if !serverURL.isEmpty { UserDefaults.standard.set(serverURL, forKey: Self.urlKey) }
        if !token.isEmpty { Keychain.save(token, for: Self.tokenAccount) }
    }

    var isConfigured: Bool { !serverURL.isEmpty && !token.isEmpty }

    #if DEBUG
        static func demo(projects: [ProjectListResult.Project]) -> AppModel {
            let model = AppModel()
            model.projects = projects
            model.screen = .projects
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

        let connection = ACPConnection(transport: WebSocketTransport(url: url, token: token))
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
            Task { await Notifier.requestAuthorization() }

            await loadProjects()
            if case .connection = screen { screen = .projects }
        } catch {
            // Un jeton refusé demande une intervention ; tout le reste est une
            // panne passagère qu'on ne doit pas faire porter à l'utilisateur.
            if isRejected(error) {
                failure = "Jeton refusé par le serveur."
                screen = .connection
            } else {
                log.notice("connexion échouée : \(error.localizedDescription, privacy: .public)")
                scheduleReconnect()
            }
        }
    }

    /// Retient les plafonds poussés sur la liaison, sans se soucier de quelle
    /// session ils viennent : ils sont les mêmes pour toutes.
    private func watchStatus(on connection: ACPConnection) async {
        let events = await connection.subscribe()
        statusWatch?.cancel()
        statusWatch = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                guard case .update(let notification) = event,
                    case .usage(_, _, let pushed) = notification.update,
                    let pushed
                else { continue }
                self?.lastStatus = pushed
            }
        }
    }

    /// Coupe volontairement — le seul chemin qui ramène à l'écran de connexion.
    func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
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
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
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
            name: safe, path: "/root/repos/\(safe)", sessionCount: 0, updatedAt: .now
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

        // Le fil est ouvert AVANT la demande : l'agent rejoue l'historique par
        // `session/update` *avant* de répondre à `session/load`. Créer le fil
        // après la réponse revenait à jeter tout le passé.
        await present(
            sessionId: summary.sessionId, cwd: cwd, title: summary.displayTitle,
            setup: nil, isResuming: true
        )

        do {
            let setup = try await connection.call(
                "session/load",
                LoadSessionParams(sessionId: summary.sessionId, cwd: cwd),
                as: SessionSetup.self
            )
            chat?.apply(setup)
        } catch {
            closeConversation()
            failure = "« \(summary.displayTitle) » : \(error.localizedDescription)"
        }
    }

    /// Supprime la conversation *et* son historique, sans corbeille.
    func delete(_ summary: SessionListResult.Summary) async {
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
        guard let connection else { return }
        // L'abonnement est ouvert **avant** que le fil existe : entre les deux,
        // c'est son tampon qui retient ce qui arrive.
        let events = await connection.subscribe()
        let session = ChatSession(
            connection: connection, events: events, workingDirectory: cwd,
            sessionId: sessionId, title: title, isResuming: isResuming,
            status: lastStatus
        )
        session.apply(setup)
        closeChat()
        chat = session
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
        guard let connection else {
            scheduleReconnect()
            return
        }
        do {
            try await connection.call("hublot/projects", Empty())
            reconnectAttempt = 0
            isReconnecting = false
        } catch {
            log.notice("liaison perdue au réveil, reprise")
            reconnectAttempt = 0
            await connect()
        }
    }
}
