//
//  ACPTransport.swift
//  Hublot
//
//  Ce qui sépare « une trame » de « comment elle voyage ». Le WebSocket est un
//  transport ; un fichier rejoué en est un autre. La connexion ne fait pas la
//  différence, et c'est ce qui permet de peupler les Previews et les tests avec
//  de vraies sessions enregistrées.
//

import Foundation

nonisolated protocol ACPTransport: Sendable {
    /// Les trames entrantes, une par élément. Le flux se termine quand la
    /// liaison tombe.
    var frames: AsyncThrowingStream<Data, Error> { get async }

    func connect() async throws
    func send(_ frame: Data) async throws
    func disconnect() async
}

nonisolated enum TransportError: LocalizedError, Sendable {
    case notConnected
    case closed(code: Int, reason: String?)
    case badURL(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Pas de liaison avec le serveur."
        case .closed(let code, let reason):
            switch code {
            case 4401: "Jeton refusé par le serveur."
            default: "Liaison fermée (\(code))\(reason.map { " — \($0)" } ?? "")."
            }
        case .badURL(let text):
            "Adresse de serveur invalide : \(text)"
        }
    }
}
