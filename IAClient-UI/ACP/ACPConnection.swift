//
//  ACPConnection.swift
//  Hublot
//
//  Le multiplexeur. Il tient la table des requêtes en vol, route ce qui
//  arrive, et sert les requêtes que l'agent adresse au client.
//
//  C'est un `actor` : la table des continuations est mutable et touchée depuis
//  la boucle de réception comme depuis chaque appel. Le rendre sûr par
//  isolation plutôt que par verrou est ce qui permet de compiler en Swift 6
//  strict sans un seul `@unchecked Sendable`.
//

import Foundation
import OSLog

actor ACPConnection {

    /// Ce que la connexion remonte à l'interface.
    nonisolated enum Event: Sendable {
        case update(SessionNotification)
        /// L'agent demande une autorisation. `respond` doit être appelé, sinon
        /// le tour reste bloqué chez l'agent.
        case permission(PermissionRequest, respond: @Sendable (PermissionResponse) async -> Void)
        case disconnected(Error?)
        /// La fin d'un tour, remise **dans la file** au lieu d'être annoncée à
        /// côté. La réponse à `session/prompt` et les derniers morceaux de texte
        /// arrivent dans la même lecture du socket, et la réponse gagne : la
        /// traiter directement revenait à déclarer le tour fini avant d'avoir
        /// posé sa dernière phrase. Passer par la file rétablit l'ordre.
        case turnFinished(sessionId: String, reason: StopReason?)
        /// Barrière placée derrière le rejeu de `session/load`. L'écran attend
        /// que son consommateur l'ait reçue avant de montrer l'historique : il
        /// apparaît ainsi directement à sa position finale, sans rattrapage
        /// visible vers le bas.
        case historyFinished(sessionId: String)
    }

    private let transport: any ACPTransport
    private let log = Logger(subsystem: "hublot", category: "acp")

    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var reader: Task<Void, Never>?

    /// Un flux **par abonné**.
    ///
    /// Il y en avait un seul, partagé — et c'était faux. Un `AsyncStream` est
    /// mono-consommateur : quand deux boucles l'itèrent, chaque élément part
    /// chez **l'une ou l'autre**, jamais chez les deux. Or l'app en a plusieurs
    /// dès qu'on ouvre une deuxième conversation, et chacune jette ce qui ne
    /// porte pas son `sessionId`. Résultat mesuré sur l'iPhone : environ une
    /// trame sur deux disparaissait — le titre d'un outil, un morceau de
    /// réponse, la fin d'un tour. La conversation semblait « se couper au
    /// milieu ». Elle ne se coupait pas : elle était lue par quelqu'un d'autre.
    private var subscribers: [Int: AsyncStream<Event>.Continuation] = [:]
    private var nextSubscriberID = 0

    init(transport: any ACPTransport) {
        self.transport = transport
    }

    /// S'abonne. Chaque appel rend un flux indépendant qui reçoit **tout**.
    ///
    /// L'abonnement prend effet au retour de cette méthode, pas au premier
    /// `for await` : le tampon de l'`AsyncStream` retient ce qui arrive entre
    /// les deux. C'est ce qui permet à `session/load` de rejouer son historique
    /// sans qu'on ait à courir après.
    func subscribe() -> AsyncStream<Event> {
        let id = nextSubscriberID
        nextSubscriberID += 1

        let (stream, continuation) = AsyncStream<Event>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    private func unsubscribe(_ id: Int) {
        subscribers.removeValue(forKey: id)
    }

    private func broadcast(_ event: Event) {
        for continuation in subscribers.values { continuation.yield(event) }
    }

    /// Range la fin d'un tour derrière tout ce qui a déjà été diffusé.
    func finishTurn(session: String, reason: StopReason?) {
        broadcast(.turnFinished(sessionId: session, reason: reason))
    }

    /// Range une barrière derrière toutes les trames de l'historique déjà
    /// diffusées. Comme chaque abonné reçoit un flux FIFO, sa réception prouve
    /// que le fil a fini d'assembler le rejeu.
    func finishHistory(session: String) {
        broadcast(.historyFinished(sessionId: session))
    }

    // MARK: Cycle de vie

    func start() async throws {
        // La liaison d'abord, le flux ensuite : c'est `connect()` qui ouvre un
        // flux neuf, et le lire avant reviendrait à écouter le précédent — mort
        // depuis la reprise, donc silencieux à jamais.
        reader?.cancel()
        try await transport.connect()
        let frames = await transport.frames
        reader = Task { await self.read(frames) }
    }

    func stop() async {
        reader?.cancel()
        reader = nil
        await transport.disconnect()
        // Personne n'attend indéfiniment une réponse qui ne viendra plus.
        for (_, continuation) in pending {
            continuation.resume(throwing: TransportError.notConnected)
        }
        pending.removeAll()
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    // MARK: Appels

    /// Au-delà, on considère la liaison morte plutôt que d'attendre sans fin.
    ///
    /// Un socket qui meurt en veille ne prévient pas : sans échéance, la
    /// première requête au réveil restait en suspens pour toujours et l'app
    /// paraissait gelée. `session/prompt` est la seule exception — une réponse
    /// peut légitimement prendre dix minutes.
    static let defaultTimeout = Duration.seconds(30)

    @discardableResult
    func call<Params: Encodable & Sendable>(
        _ method: String, _ params: Params, timeout: Duration? = defaultTimeout
    ) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let frame = try JSONCoding.encoder.encode(RPCRequest(id: id, method: method, params: params))

        let watchdog: Task<Void, Never>? = timeout.map { limit in
            Task { [weak self] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                await self?.expire(id, method: method)
            }
        }

        defer { watchdog?.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await transport.send(frame)
                } catch {
                    if let waiting = pending.removeValue(forKey: id) {
                        waiting.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func expire(_ id: Int, method: String) {
        guard let waiting = pending.removeValue(forKey: id) else { return }
        log.notice("\(method, privacy: .public) sans réponse, liaison présumée morte")
        waiting.resume(throwing: TransportError.notConnected)
    }

    func call<Params: Encodable & Sendable, Result: Decodable>(
        _ method: String, _ params: Params, as type: Result.Type,
        timeout: Duration? = defaultTimeout
    ) async throws -> Result {
        try await call(method, params, timeout: timeout).decode(Result.self)
    }

    func notify<Params: Encodable & Sendable>(_ method: String, _ params: Params) async throws {
        let frame = try JSONCoding.encoder.encode(RPCNotification(method: method, params: params))
        try await transport.send(frame)
    }

    // MARK: Réception

    private func read(_ frames: AsyncThrowingStream<Data, Error>) async {
        do {
            for try await frame in frames {
                guard !Task.isCancelled else { return }
                handle(frame)
            }
            broadcast(.disconnected(nil))
        } catch {
            broadcast(.disconnected(error))
        }
    }

    private func handle(_ frame: Data) {
        let message: IncomingMessage
        do {
            message = try JSONCoding.decoder.decode(IncomingMessage.self, from: frame)
        } catch {
            // Une trame illisible n'est pas une raison de couper la
            // conversation : on la note et on continue.
            log.error("trame illisible ignorée : \(error.localizedDescription, privacy: .public)")
            return
        }

        switch message {
        case .response(let id, let result):
            pending.removeValue(forKey: id)?.resume(returning: result)

        case .failure(let id, let error):
            pending.removeValue(forKey: id)?.resume(throwing: error)

        case .notification(let method, let params):
            guard method == "session/update" else {
                log.debug("notification ignorée : \(method, privacy: .public)")
                return
            }
            guard let notification = try? params.decode(SessionNotification.self) else {
                log.error("session/update indécodable")
                return
            }
            broadcast(.update(notification))

        case .request(let id, let method, let params):
            serve(id: id, method: method, params: params)
        }
    }

    /// Les requêtes que l'agent adresse au client.
    ///
    /// Seule la permission nous concerne : l'app annonce `fs` et `terminal` à
    /// `false`, donc l'agent ne doit pas nous les demander. S'il le fait quand
    /// même, on répond une erreur propre plutôt que de le laisser attendre.
    private func serve(id: Int, method: String, params: JSONValue) {
        switch method {
        case "session/request_permission":
            guard let request = try? params.decode(PermissionRequest.self) else {
                reply(id: id, error: .init(code: -32602, message: "demande de permission illisible"))
                return
            }
            broadcast(
                .permission(request) { [weak self] response in
                    await self?.reply(id: id, result: response)
                }
            )

        default:
            log.notice("méthode agent→client non servie : \(method, privacy: .public)")
            reply(id: id, error: .init(code: RPCError.methodNotFound, message: "non pris en charge"))
        }
    }

    private func reply<Result: Encodable & Sendable>(id: Int, result: Result) {
        guard let frame = try? JSONCoding.encoder.encode(RPCReply(id: id, result: result)) else { return }
        Task { try? await transport.send(frame) }
    }

    private func reply(id: Int, error: RPCError) {
        guard let frame = try? JSONCoding.encoder.encode(RPCErrorReply(id: id, error: error)) else { return }
        Task { try? await transport.send(frame) }
    }
}
