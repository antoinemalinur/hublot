//
//  ACPCodingEdgeTests.swift
//  Hublot
//
//  Les bords du codage : une date ecrite par Python, une trame sans
//  identifiant, un bloc de contenu qui n'est ni texte ni image, une variante de
//  `session/update` arrivee sans sa charge.
//
//  Aucun de ces cas n'apparait dans une capture nominale, et tous viennent d'un
//  vrai defaut : `ISO8601DateFormatter` n'accepte que trois decimales de
//  seconde quand Python en ecrit six, et le refus faisait tomber le bloc entier
//  qui portait la date.
//

import Foundation
import Testing

@testable import IAClient_UI

@Suite("Bords du codage ACP")
struct ACPCodingEdgeTests {

    private struct Stamped: Decodable { let at: Date }

    private func date(_ text: String) throws -> Date {
        try JSONCoding.decoder.decode(
            Stamped.self, from: Data(#"{"at":"\#(text)"}"#.utf8)
        ).at
    }

    // MARK: Les dates

    @Test("Une date ecrite par Python garde sa seconde malgre ses six decimales")
    func sixDigitFractionIsAccepted() throws {
        // Le cas reel : la barre d'etat affichait « — » parce que le bloc
        // entier tombait sur cette seule fraction.
        let long = try date("2026-08-06T03:11:42.826682+00:00")
        let short = try date("2026-08-06T03:11:42.826+00:00")
        #expect(abs(long.timeIntervalSince(short)) < 0.001)
    }

    @Test("Une date sans fraction reste lisible")
    func plainDateIsAccepted() throws {
        // Le formateur a fraction refuse une date qui n'en porte pas : c'est le
        // second essai, celui qui retire la fraction, qui doit la rattraper.
        let plain = try date("2026-08-06T03:11:42Z")
        #expect(plain == (try date("2026-08-06T03:11:42.000Z")))
        #expect(plain < (try date("2026-08-06T03:11:43Z")))
    }

    @Test("Une date sans fuseau est refusee au lieu d'etre devinee")
    func dateWithoutZoneIsRejected() {
        // La fraction va jusqu'au bout de la chaine : ni la normalisation ni le
        // retrait ne trouvent de caractere apres les chiffres.
        #expect(throws: (any Error).self) { try date("2026-08-06T03:11:42.826682") }
    }

    @Test("Un texte qui n'est pas une date le dit franchement")
    func nonsenseDateThrows() {
        #expect(throws: (any Error).self) { try date("hier soir") }
    }

    // MARK: Les valeurs JSON

    @Test("Une valeur JSON ne se laisse lire que dans son propre type")
    func jsonValueReadsOnlyItsOwnType() {
        #expect(JSONValue.number(42).intValue == 42)
        #expect(JSONValue.string("42").intValue == nil)
        #expect(JSONValue.string("texte").stringValue == "texte")
        #expect(JSONValue.number(1).stringValue == nil)
        #expect(JSONValue.object(["a": .number(1)])["a"]?.intValue == 1)
        #expect(JSONValue.string("plat")["a"] == nil)
    }

    // MARK: Les enveloppes sortantes

    @Test("Chaque enveloppe sortante porte sa version de protocole")
    func outgoingEnvelopesCarryTheirVersion() throws {
        let request = try text(of: RPCRequest(id: 1, method: "initialize", params: Empty()))
        let notification = try text(of: RPCNotification(method: "session/cancel", params: Empty()))
        let reply = try text(of: RPCReply(id: 2, result: Empty()))
        let failure = try text(
            of: RPCErrorReply(id: 3, error: RPCError(code: -32000, message: "refus", data: nil))
        )

        for frame in [request, notification, reply, failure] {
            #expect(frame.contains(#""jsonrpc":"2.0""#))
        }
        #expect(request.contains(#""method":"initialize""#))
        #expect(failure.contains(#""code":-32000"#))
    }

    private func text(of value: some Encodable) throws -> String {
        String(decoding: try JSONCoding.encoder.encode(value), as: UTF8.self)
    }

    // MARK: Les trames entrantes

    @Test("Une trame sans identifiant est une notification, pas une reponse")
    func methodWithoutIdIsANotification() throws {
        let message = try JSONCoding.decoder.decode(
            IncomingMessage.self,
            from: Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"a":1}}"#.utf8)
        )
        guard case .notification(let method, let params) = message else {
            Issue.record("une trame sans id devrait etre une notification")
            return
        }
        #expect(method == "session/update")
        #expect(params["a"]?.intValue == 1)
    }

    @Test("Une trame sans identifiant ni methode est refusee")
    func framelessMessageIsRejected() {
        #expect(throws: (any Error).self) {
            try JSONCoding.decoder.decode(
                IncomingMessage.self, from: Data(#"{"jsonrpc":"2.0"}"#.utf8)
            )
        }
    }

    // MARK: Les blocs de contenu

    @Test("Une image jointe survit a l'aller-retour, une ressource inconnue aussi")
    func contentBlocksSurviveRoundTrip() throws {
        let image = try JSONCoding.decoder.decode(
            ContentBlock.self,
            from: Data(#"{"type":"image","mimeType":"image/png","data":"AAAB"}"#.utf8)
        )
        guard case .image(let mimeType, let data) = image else {
            Issue.record("le bloc image n'est pas reconnu")
            return
        }
        #expect(mimeType == "image/png")
        #expect(data == "AAAB")

        // Ni texte ni image : conserve brut plutot qu'ignore.
        let resource = try JSONCoding.decoder.decode(
            ContentBlock.self,
            from: Data(#"{"type":"resource_link","uri":"file:///tmp/a.txt"}"#.utf8)
        )
        guard case .other(let value) = resource else {
            Issue.record("la ressource devrait etre conservee telle quelle")
            return
        }
        #expect(value["uri"]?.stringValue == "file:///tmp/a.txt")

        for block in [ContentBlock.text("bonjour"), image, resource] {
            let encoded = try JSONCoding.encoder.encode(block)
            let again = try JSONCoding.decoder.decode(ContentBlock.self, from: encoded)
            #expect(again == block)
        }
    }

    @Test("Un bloc image sans type explicite garde un format par defaut")
    func imageWithoutMimeTypeFallsBack() throws {
        let block = try JSONCoding.decoder.decode(
            ContentBlock.self, from: Data(#"{"type":"image"}"#.utf8)
        )
        guard case .image(let mimeType, let data) = block else {
            Issue.record("le bloc image n'est pas reconnu")
            return
        }
        #expect(mimeType == "image/jpeg")
        #expect(data.isEmpty)
    }

    // MARK: Les reglages

    @Test("Un reglage affiche le libelle de sa valeur, pas sa valeur brute")
    func settingShowsItsLabel() throws {
        let option = try JSONCoding.decoder.decode(
            ConfigOption.self,
            from: Data(
                """
                {"id":"model","name":"Modele","type":"select","currentValue":"opus",\
                "options":[{"value":"opus","name":"Opus"},{"value":"sonnet","name":"Sonnet"}]}
                """.utf8
            )
        )
        #expect(option.currentLabel == "Opus")
        #expect(option.options?.first?.id == "opus")

        // Sans valeur courante, le nom du reglage tient lieu de libelle.
        let unset = try JSONCoding.decoder.decode(
            ConfigOption.self,
            from: Data(#"{"id":"mode","name":"Mode","type":"select"}"#.utf8)
        )
        #expect(unset.currentLabel == "Mode")

        // Une valeur que l'agent n'a pas nommee reste affichable telle quelle.
        let unnamed = try JSONCoding.decoder.decode(
            ConfigOption.self,
            from: Data(#"{"id":"mode","name":"Mode","type":"select","currentValue":"brut"}"#.utf8)
        )
        #expect(unnamed.currentLabel == "brut")
    }

    // MARK: Les variantes de session/update

    @Test("Une variante arrivee sans sa charge vaut une charge vide")
    func updatesWithoutPayloadDegradeToEmpty() throws {
        guard case .plan(let entries) = try update(#"{"sessionUpdate":"plan"}"#) else {
            Issue.record("la variante plan n'est pas reconnue")
            return
        }
        #expect(entries.isEmpty)

        guard case .availableCommands(let commands) = try update(
            #"{"sessionUpdate":"available_commands_update"}"#
        ) else {
            Issue.record("la variante des commandes n'est pas reconnue")
            return
        }
        #expect(commands.isEmpty)

        guard case .currentMode(let mode) = try update(
            #"{"sessionUpdate":"current_mode_update"}"#
        ) else {
            Issue.record("la variante de mode n'est pas reconnue")
            return
        }
        #expect(mode.isEmpty)
    }

    @Test("Une variante inconnue est nommee au lieu d'etre perdue")
    func unknownUpdateKeepsItsName() throws {
        guard case .unrecognised(let kind) = try update(
            #"{"sessionUpdate":"quelque_chose_de_neuf"}"#
        ) else {
            Issue.record("la variante inconnue devrait etre nommee")
            return
        }
        #expect(kind == "quelque_chose_de_neuf")
    }

    private func update(_ json: String) throws -> SessionUpdate {
        try JSONCoding.decoder.decode(SessionUpdate.self, from: Data(json.utf8))
    }
}
