//
//  WebSocketTransport.swift
//  Hublot
//
//  `URLSessionWebSocketTask`, rien d'autre : pas de bibliothèque tierce pour
//  quelque chose que la bibliothèque standard fait bien.
//

import Foundation
import OSLog

actor WebSocketTransport: ACPTransport {
    private let url: URL
    private let token: String
    private let session: URLSession

    private var task: URLSessionWebSocketTask?
    /// Le flux courant, **retenu**. Il était recalculé à chaque lecture de
    /// `frames`, et chaque recalcul écrasait la continuation : le lecteur en
    /// place se retrouvait branché sur un tuyau que plus personne n'alimentait.
    private var stream: AsyncThrowingStream<Data, Error>?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var heartbeat: Task<Void, Never>?
    private var pump: Task<Void, Never>?

    private let log = Logger(subsystem: "hublot", category: "transport")

    /// Toutes les 25 s. Les mandataires coupent les liaisons inactives bien
    /// avant la minute ; c'est une trame RFC 6455, honorée par les
    /// intermédiaires, et surtout elle **ne demande rien à l'agent** —
    /// contrairement à un `$/ping` applicatif, qui exigerait un accord avec le
    /// serveur du VPS.
    private static let heartbeatInterval = Duration.seconds(25)

    init(url: URL, token: String, session: URLSession? = nil) {
        self.url = url
        self.token = token
        self.session = session ?? Self.makeSession()
    }

    /// `URLSession.shared` coupe une requête inactive au bout de 60 s et
    /// échoue tout de suite s'il n'y a pas de réseau — deux comportements
    /// désastreux pour une liaison persistante sur un téléphone qui entre et
    /// sort du Wi-Fi. D'où une session dédiée.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = .infinity
        return URLSession(configuration: configuration)
    }

    /// Le flux ouvert par la dernière connexion. Lu avant toute connexion, il
    /// en ouvre un d'avance plutôt que d'en inventer un nouveau à chaque appel.
    var frames: AsyncThrowingStream<Data, Error> {
        if let stream { return stream }
        return openStream()
    }

    private func openStream() -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.stream = stream
        self.continuation = continuation
        return stream
    }

    func connect() async throws {
        disconnectSynchronously()
        _ = openStream()

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Le jeton passe aussi en en-tête *et* en paramètre côté pont ; ici on
        // s'en tient à l'en-tête, que `URLSessionWebSocketTask` sait poser.

        let task = session.webSocketTask(with: request)
        // `URLSessionWebSocketTask` refuse par défaut toute trame de plus d'un
        // mégaoctet — et il ne la saute pas : il **coupe la liaison**, avec pour
        // seul signe une erreur de lecture. Le `rawInput` d'une écriture de
        // fichier suffit à dépasser ce plafond, et la conversation s'arrêtait
        // alors au milieu d'un outil, sans un mot.
        task.maximumMessageSize = 16 * 1024 * 1024
        self.task = task
        task.resume()

        pump = Task { await self.receiveLoop(task) }
        heartbeat = Task { await self.heartbeatLoop(task) }
        log.info("liaison ouverte vers \(self.url.absoluteString, privacy: .public)")
    }

    func send(_ frame: Data) async throws {
        guard let task else { throw TransportError.notConnected }
        guard let text = String(data: frame, encoding: .utf8) else { return }
        // ACP est du JSON par ligne : on envoie du texte, pas du binaire, pour
        // que le pont et Caddy voient exactement ce qu'ils attendent.
        try await task.send(.string(text))
    }

    func disconnect() async {
        disconnectSynchronously()
    }

    // MARK: Interne

    private func disconnectSynchronously() {
        heartbeat?.cancel()
        pump?.cancel()
        heartbeat = nil
        pump = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        // Le lecteur d'en face doit voir la liaison finir, sinon il attend une
        // trame qui ne viendra plus.
        continuation?.finish()
        continuation = nil
        stream = nil
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                switch try await task.receive() {
                case .string(let text):
                    // Une trame WebSocket peut porter plusieurs lignes JSON :
                    // le pont relaie ligne à ligne, mais rien ne l'impose au
                    // serveur du VPS.
                    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                        continuation?.yield(Data(line.utf8))
                    }
                case .data(let data):
                    continuation?.yield(data)
                @unknown default:
                    continue
                }
            } catch {
                guard !Task.isCancelled else { return }
                log.error("liaison perdue : \(error.localizedDescription, privacy: .public)")
                continuation?.finish(throwing: error)
                return
            }
        }
    }

    private func heartbeatLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.heartbeatInterval)
            guard !Task.isCancelled else { return }
            await withCheckedContinuation { continuation in
                task.sendPing { _ in continuation.resume() }
            }
        }
    }
}
