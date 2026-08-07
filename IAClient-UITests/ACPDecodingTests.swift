//
//  ACPDecodingTests.swift
//  Hublot
//
//  Les trames de ce fichier sont **copiées telles quelles** de
//  `Fixtures/*.jsonl`, enregistrées au pont local face à
//  `@agentclientprotocol/claude-agent-acp`. Pas d'exemples réécrits à notre
//  avantage : si l'agent change de forme, ces tests doivent tomber.
//

import Foundation
import Testing

@testable import IAClient_UI

@Suite("Décodage ACP")
struct ACPDecodingTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test("Les dates de session/list se décodent, fraction de seconde comprise")
    func listeDesSessions() throws {
        // Le bug qui a coûté un aller-retour : le décodeur par défaut attend un
        // nombre de secondes, l'agent envoie de l'ISO 8601. `session/list`
        // échouait en silence et l'app affichait « aucune session » alors que
        // le serveur en avait cinq.
        let result = try decode(
            SessionListResult.self,
            """
            {"sessions":[
              {"sessionId":"8227c892","cwd":"/repo","title":"Avec fraction",
               "updatedAt":"2026-08-06T03:11:42.511Z"},
              {"sessionId":"7a8d22b1","cwd":"/repo","title":"Sans fraction",
               "updatedAt":"2026-08-06T03:11:42Z"},
              {"sessionId":"43accb8a"}]}
            """)

        #expect(result.sessions.count == 3)
        #expect(result.sessions[0].updatedAt != nil)
        #expect(result.sessions[1].updatedAt != nil)
        // Une session sans date ni titre ne doit pas faire tomber la liste.
        #expect(result.sessions[2].updatedAt == nil)
        #expect(result.sessions[2].displayTitle == "Session sans titre")
    }

    @Test("Une date à six décimales de seconde se décode")
    func fractionsDeSeconde() throws {
        // Python écrit six décimales ; `ISO8601DateFormatter` n'en accepte que
        // trois et refusait la valeur. Tout le bloc qui la contenait tombait
        // alors à `nil` — la barre d'état affichait « — » avec de bons chiffres
        // sur le fil.
        let result = try decode(
            SessionListResult.self,
            """
            {"sessions":[
              {"sessionId":"a","updatedAt":"2026-08-06T22:59:59.826682+00:00"},
              {"sessionId":"b","updatedAt":"2026-08-06T22:59:59.826+00:00"},
              {"sessionId":"c","updatedAt":"2026-08-06T22:59:59Z"}]}
            """)

        #expect(result.sessions.allSatisfy { $0.updatedAt != nil })
        // Les trois désignent le même instant à la milliseconde près.
        let seconds = result.sessions.compactMap { $0.updatedAt?.timeIntervalSince1970 }
        #expect(seconds.max()! - seconds.min()! < 1)
    }

    @Test("Un titre trop long est coupé pour tenir sur une ligne")
    func titreCoupe() {
        let long = String(repeating: "a", count: 200)
        let summary = SessionListResult.Summary(sessionId: "s", title: long)
        #expect(summary.displayTitle.count == 70)
        #expect(summary.displayTitle.hasSuffix("…"))
    }

    // MARK: Aiguillage JSON-RPC

    @Test("Les quatre formes JSON-RPC sont distinguées")
    func formesJSONRPC() throws {
        let response = try decode(
            IncomingMessage.self, #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}"#)
        guard case .response(let id, _) = response else {
            Issue.record("attendu une réponse"); return
        }
        #expect(id == 1)

        let failure = try decode(
            IncomingMessage.self,
            #"{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"Method not found"}}"#)
        guard case .failure(_, let error) = failure else {
            Issue.record("attendu un échec"); return
        }
        #expect(error.isMethodNotFound)

        let notification = try decode(
            IncomingMessage.self,
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s"}}"#)
        guard case .notification(let method, _) = notification else {
            Issue.record("attendu une notification"); return
        }
        #expect(method == "session/update")

        let request = try decode(
            IncomingMessage.self,
            #"{"jsonrpc":"2.0","id":9,"method":"session/request_permission","params":{}}"#)
        guard case .request(_, let requested, _) = request else {
            Issue.record("attendu une requête"); return
        }
        #expect(requested == "session/request_permission")
    }

    // MARK: Capacités

    @Test("Les capacités de session s'annoncent par présence de clé")
    func capacites() throws {
        // Relevé au pont : l'agent n'envoie pas de booléens, il envoie des
        // objets vides. `"list": {}` veut dire « je sais lister ».
        let result = try decode(
            InitializeResult.self,
            """
            {"protocolVersion":1,
             "agentCapabilities":{
               "loadSession":true,
               "promptCapabilities":{"image":true,"embeddedContext":true},
               "sessionCapabilities":{"close":{},"delete":{},"fork":{},"list":{},"resume":{}}},
             "agentInfo":{"name":"@agentclientprotocol/claude-agent-acp","version":"0.49.0"},
             "authMethods":[]}
            """)

        #expect(result.protocolVersion == 1)
        #expect(result.agentCapabilities?.supportsListing == true)
        #expect(result.agentCapabilities?.supportsResume == true)
        #expect(result.agentCapabilities?.supportsLoad == true)
        #expect(result.agentInfo?.version == "0.49.0")
    }

    // MARK: Notifications

    @Test("Un morceau de message porte son messageId")
    func morceauDeMessage() throws {
        let notification = try decode(
            SessionNotification.self,
            """
            {"sessionId":"7a8d22b1",
             "update":{"sessionUpdate":"agent_message_chunk",
                       "content":{"type":"text","text":"Voici "},
                       "messageId":"msg_011Cdkc66fd6CHtW5T2qPC3D"}}
            """)

        guard case .agentMessageChunk(let messageId, let content) = notification.update else {
            Issue.record("attendu agent_message_chunk"); return
        }
        #expect(messageId == "msg_011Cdkc66fd6CHtW5T2qPC3D")
        #expect(content.text == "Voici ")
    }

    @Test("Le statut in_progress se décode depuis le snake_case du fil")
    func statutSnakeCase() throws {
        let notification = try decode(
            SessionNotification.self,
            """
            {"sessionId":"s","update":{"sessionUpdate":"tool_call",
             "toolCallId":"toolu_1","status":"in_progress","title":"Read File","kind":"read"}}
            """)

        guard case .toolCall(let payload) = notification.update else {
            Issue.record("attendu tool_call"); return
        }
        #expect(payload.status == .inProgress)
        #expect(payload.kind == .read)
    }

    @Test("Une mise à jour d'outil porte aussi le titre et le vrai nom de l'outil")
    func miseAJourOutil() throws {
        // Le point que la documentation manque : `tool_call_update` ne se limite
        // pas au statut. C'est elle qui remplace « Read File » par le vrai
        // chemin, et `_meta` qui donne le nom d'outil affichable.
        let notification = try decode(
            SessionNotification.self,
            """
            {"sessionId":"s",
             "update":{"_meta":{"claudeCode":{"toolName":"Read"}},
               "toolCallId":"toolu_019pWCYq7mQrxeEeWek7Qhw2",
               "sessionUpdate":"tool_call_update",
               "rawInput":{"file_path":"/tmp/acp-probe.mjs"},
               "title":"Read Tools/acp-probe.mjs",
               "kind":"read",
               "locations":[{"path":"/tmp/acp-probe.mjs","line":1}],
               "content":[]}}
            """)

        guard case .toolCallUpdate(let payload) = notification.update else {
            Issue.record("attendu tool_call_update"); return
        }
        #expect(payload.title == "Read Tools/acp-probe.mjs")
        #expect(payload.toolName == "Read")
        #expect(payload.locations?.first?.line == 1)
        // Absent de la trame : doit rester nil pour que la fusion ne l'écrase pas.
        #expect(payload.status == nil)
    }

    @Test("Une variante inconnue n'interrompt pas le flux")
    func varianteInconnue() throws {
        // Le protocole bouge. Une nouveauté doit se traduire par « ça ne
        // s'affiche pas », jamais par « la conversation se coupe ».
        let notification = try decode(
            SessionNotification.self,
            #"{"sessionId":"s","update":{"sessionUpdate":"quelque_chose_de_neuf","payload":42}}"#)

        guard case .unrecognised(let kind) = notification.update else {
            Issue.record("attendu une variante non reconnue"); return
        }
        #expect(kind == "quelque_chose_de_neuf")
    }

    @Test("La consommation de contexte se décode")
    func usage() throws {
        let notification = try decode(
            SessionNotification.self,
            #"{"sessionId":"s","update":{"sessionUpdate":"usage_update","used":12695,"size":200000}}"#)

        guard case .usage(let used, let size, _) = notification.update else {
            Issue.record("attendu usage_update"); return
        }
        #expect(used == 12695)
        #expect(size == 200_000)
    }

    @Test("Les plafonds voyagent dans _meta sans casser un client ordinaire")
    func plafonds() throws {
        // Le serveur du VPS pousse modèle, effort, moteur et quotas dans
        // `_meta.hublot`. Un client ACP qui l'ignore décode quand même la
        // consommation de contexte — c'est tout l'intérêt de les mettre là.
        let notification = try decode(
            SessionNotification.self,
            """
            {"sessionId":"s","update":{"sessionUpdate":"usage_update",
             "used":12695,"size":1000000,
             "_meta":{"hublot":{"model":"Opus 4.8","effort":"high","engine":"claude",
               "limits":{"five_hour":{"percent":58,"resetsAt":"2026-08-06T12:59:59.676430+00:00"},
                         "seven_day":{"percent":44,"resetsAt":"2026-08-10T16:59:59.676450+00:00"}}}}}}
            """)

        guard case .usage(_, _, let status) = notification.update else {
            Issue.record("attendu usage_update"); return
        }
        #expect(status?.model == "Opus 4.8")
        #expect(status?.engine == "claude")
        #expect(status?.fiveHour?.percent == 58)
        #expect(status?.weekly?.percent == 44)
        // Le reste à courir se calcule, il n'est pas transmis.
        #expect(status?.fiveHour?.remaining != nil)
    }

    // MARK: Permissions

    @Test("Une demande de permission garde les libellés de l'agent")
    func permission() throws {
        let request = try decode(
            PermissionRequest.self,
            """
            {"sessionId":"s",
             "toolCall":{"toolCallId":"toolu_2","title":"Bash","kind":"execute"},
             "options":[{"optionId":"a","name":"Autoriser une fois","kind":"allow_once"},
                        {"optionId":"b","name":"Toujours autoriser","kind":"allow_always"},
                        {"optionId":"c","name":"Refuser","kind":"reject_once"}]}
            """)

        #expect(request.options.map(\.name) == [
            "Autoriser une fois", "Toujours autoriser", "Refuser",
        ])
        #expect(request.options[0].kind == .allowOnce)
        #expect(request.options[2].kind.isRejection)
    }

    @Test("La réponse à une permission a l'imbrication du protocole")
    func reponsePermission() throws {
        let data = try JSONEncoder().encode(PermissionResponse.selected("option-42"))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(decoded["outcome"]?["outcome"]?.stringValue == "selected")
        #expect(decoded["outcome"]?["optionId"]?.stringValue == "option-42")
    }

    // MARK: Raisons d'arrêt

    @Test("Les raisons d'arrêt couvrent le vocabulaire du protocole")
    func raisonsDArret() throws {
        let expected: [String: StopReason] = [
            "end_turn": .endTurn,
            "max_tokens": .maxTokens,
            "max_turn_requests": .maxTurnRequests,
            "refusal": .refusal,
            "cancelled": .cancelled,
        ]
        for (wire, reason) in expected {
            let result = try decode(PromptResult.self, #"{"stopReason":"\#(wire)"}"#)
            #expect(result.stopReason == reason)
        }
    }
}
