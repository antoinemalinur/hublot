//
//  JSONRPC.swift
//  Hublot
//
//  ACP est du JSON-RPC 2.0, une trame par ligne. Cette couche ne connaît rien
//  d'ACP ni de SwiftUI : elle sait seulement encoder des requêtes et
//  reconnaître ce qui arrive.
//

import Foundation

// MARK: - Codage

/// Le codec du protocole, en un seul endroit.
///
/// La stratégie de date n'est pas un détail : l'agent envoie
/// `"2026-08-06T03:11:42.511Z"`, et le décodeur par défaut attend un nombre de
/// secondes. Sans ça, `session/list` échouait en silence et l'app affichait
/// « aucune session » alors que le serveur en avait cinq.
nonisolated enum JSONCoding {

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "date ACP illisible : \(text)")
                )
            }
            return date
        }
        return decoder
    }

    static var encoder: JSONEncoder { JSONEncoder() }

    /// Analyse une date ACP, quelle que soit sa précision.
    ///
    /// `ISO8601DateFormatter` n'accepte que **trois** décimales de seconde.
    /// Python en écrit six (`…:59.826682+00:00`), et le refus faisait échouer
    /// tout le bloc qui la contenait : la barre d'état affichait « — » alors
    /// que le serveur envoyait les bons chiffres. On normalise donc la fraction
    /// avant de laisser le formateur travailler.
    ///
    /// Les formateurs sont construits à la demande : `ISO8601DateFormatter`
    /// n'est pas `Sendable`, et le partager entre isolations serait une course.
    fileprivate static func parseDate(_ text: String) -> Date? {
        let normalised = normaliseFraction(text)

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: normalised) { return date }

        return ISO8601DateFormatter().date(from: stripFraction(text))
    }

    /// Ramène `.826682` à `.826`, sans toucher au reste.
    private static func normaliseFraction(_ text: String) -> String {
        guard let dot = text.firstIndex(of: ".") else { return text }
        let after = text.index(after: dot)
        guard let end = text[after...].firstIndex(where: { !$0.isNumber }) else {
            return text
        }
        let digits = text[after..<end]
        guard digits.count > 3 else { return text }
        return String(text[..<after]) + String(digits.prefix(3)) + String(text[end...])
    }

    private static func stripFraction(_ text: String) -> String {
        guard let dot = text.firstIndex(of: ".") else { return text }
        let after = text.index(after: dot)
        guard let end = text[after...].firstIndex(where: { !$0.isNumber }) else {
            return String(text[..<dot])
        }
        return String(text[..<dot]) + String(text[end...])
    }
}

// MARK: - Valeur JSON

/// Une valeur JSON quelconque.
///
/// Nécessaire parce que le protocole transporte des charges dont la forme
/// dépend de l'agent : `rawInput` d'un outil, `_meta`, les options de
/// configuration. On les garde telles quelles et on ne décode en type précis
/// que ce dont on a besoin.
nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "valeur JSON non reconnue"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Accès

    subscript(key: String) -> JSONValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(value)
    }

    /// Relit la valeur en un type précis.
    ///
    /// L'aller-retour par `Data` est délibéré : il évite d'écrire un décodeur
    /// maison pour chaque charge, au prix d'un encodage supplémentaire sur des
    /// objets qui font quelques kilo-octets au plus. À reconsidérer seulement si
    /// une mesure le désigne.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONCoding.encoder.encode(self)
        return try JSONCoding.decoder.decode(T.self, from: data)
    }
}

// MARK: - Sortant

nonisolated struct RPCRequest<Params: Encodable & Sendable>: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Params

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }
}

nonisolated struct RPCNotification<Params: Encodable & Sendable>: Encodable, Sendable {
    let jsonrpc = "2.0"
    let method: String
    let params: Params

    private enum CodingKeys: String, CodingKey { case jsonrpc, method, params }
}

/// La réponse à une requête *de l'agent* — permission, lecture de fichier.
nonisolated struct RPCReply<Result: Encodable & Sendable>: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: Int
    let result: Result

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, result }
}

nonisolated struct RPCErrorReply: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: Int
    let error: RPCError

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, error }
}

/// Une charge vide, pour les méthodes sans paramètre.
nonisolated struct Empty: Codable, Sendable {
    init() {}
}

// MARK: - Entrant

nonisolated struct RPCError: Codable, Hashable, Sendable, Error {
    let code: Int
    let message: String
    var data: JSONValue?

    /// JSON-RPC 2.0 : méthode inconnue de l'autre bout.
    static let methodNotFound = -32601

    var isMethodNotFound: Bool { code == Self.methodNotFound }
}

/// Ce qui peut arriver sur le fil. Les quatre formes du protocole, distinguées
/// par la présence de `id`, `method`, `result` et `error`.
nonisolated enum IncomingMessage: Decodable, Sendable {
    /// Réponse à une requête qu'on a émise.
    case response(id: Int, result: JSONValue)
    /// Échec d'une requête qu'on a émise.
    case failure(id: Int, error: RPCError)
    /// Requête de l'agent, à laquelle il faut répondre.
    case request(id: Int, method: String, params: JSONValue)
    /// Notification de l'agent : rien à renvoyer.
    case notification(method: String, params: JSONValue)

    private enum CodingKeys: String, CodingKey { case id, method, params, result, error }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(Int.self, forKey: .id)
        let method = try container.decodeIfPresent(String.self, forKey: .method)
        let params = try container.decodeIfPresent(JSONValue.self, forKey: .params) ?? .null

        if let method {
            if let id {
                self = .request(id: id, method: method, params: params)
            } else {
                self = .notification(method: method, params: params)
            }
            return
        }

        guard let id else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container, debugDescription: "trame sans id ni method"
            )
        }

        if let error = try container.decodeIfPresent(RPCError.self, forKey: .error) {
            self = .failure(id: id, error: error)
        } else {
            self = .response(
                id: id,
                result: try container.decodeIfPresent(JSONValue.self, forKey: .result) ?? .null
            )
        }
    }
}
