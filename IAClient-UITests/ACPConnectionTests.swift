import Foundation
import Testing

@testable import IAClient_UI

@Suite("Multiplexeur ACP")
struct ACPConnectionTests {
    @Test("Deux appels concurrents gardent des identifiants distincts et acceptent les reponses inversees")
    func concurrentCallsOutOfOrder() async throws {
        let transport = ProbeTransport()
        let connection = ACPConnection(transport: transport)
        try await connection.start()

        let first = Task { try await connection.call("first", Empty(), timeout: nil) }
        let second = Task { try await connection.call("second", Empty(), timeout: nil) }
        let sent = await waitForSent(2, by: transport)
        let requests = try sent.map { try JSONCoding.decoder.decode(IncomingMessage.self, from: $0) }
        let ids = requests.compactMap { message -> Int? in
            guard case .request(let id, _, _) = message else { return nil }
            return id
        }
        #expect(Set(ids).count == 2)

        await transport.push(try JSONCoding.encoder.encode(RPCReply(id: ids[1], result: "second")))
        await transport.push(try JSONCoding.encoder.encode(RPCReply(id: ids[0], result: "first")))

        #expect(try await first.value.stringValue == "first")
        #expect(try await second.value.stringValue == "second")
        await connection.stop()
    }

    @Test("Un echec d'envoi libere immediatement l'appel")
    func sendFailure() async throws {
        let transport = ProbeTransport(sendFailure: true)
        let connection = ACPConnection(transport: transport)
        try await connection.start()

        do {
            _ = try await connection.call("broken", Empty(), timeout: nil)
            Issue.record("l'appel aurait du echouer")
        } catch {
            #expect(error is ProbeFailure)
        }
        await connection.stop()
    }

    @Test("Arreter la connexion libere toutes les requetes pendantes")
    func stopReleasesPendingCalls() async throws {
        let transport = ProbeTransport()
        let connection = ACPConnection(transport: transport)
        try await connection.start()

        let pending = Task { try await connection.call("never", Empty(), timeout: nil) }
        _ = await waitForSent(1, by: transport)
        await connection.stop()

        do {
            _ = try await pending.value
            Issue.record("la requete est restee vivante apres stop")
        } catch {
            guard case TransportError.notConnected = error else {
                Issue.record("mauvaise erreur: \(error)")
                return
            }
        }
    }

    @Test("L'echeance injectable expire sans attendre trente secondes")
    func injectedTimeout() async throws {
        let transport = ProbeTransport()
        let connection = ACPConnection(transport: transport) { _ in
            await Task.yield()
        }
        try await connection.start()

        do {
            _ = try await connection.call("slow", Empty(), timeout: .seconds(30))
            Issue.record("l'echeance n'a pas expire")
        } catch {
            guard case TransportError.notConnected = error else {
                Issue.record("mauvaise erreur: \(error)")
                return
            }
        }
        await connection.stop()
    }

    @Test("Chaque abonne recoit la meme notification")
    func everySubscriberReceivesEveryUpdate() async throws {
        let transport = ProbeTransport()
        let connection = ACPConnection(transport: transport)
        try await connection.start()
        let first = await connection.subscribe()
        let second = await connection.subscribe()
        let firstEvent = Task.detached { () -> ACPConnection.Event? in
            for await event in first { return event }
            return nil
        }
        let secondEvent = Task.detached { () -> ACPConnection.Event? in
            for await event in second { return event }
            return nil
        }

        await transport.push(Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"shared","update":{"sessionUpdate":"agent_message_chunk","messageId":"m","content":{"type":"text","text":"bonjour"}}}}"#.utf8))

        for event in [await firstEvent.value, await secondEvent.value] {
            guard case .update(let notification) = event else {
                Issue.record("notification absente chez un abonne")
                continue
            }
            #expect(notification.sessionId == "shared")
        }
        await connection.stop()
    }

    @Test("Une trame invalide est ignoree et la suivante repond encore")
    func invalidFrameDoesNotBreakReader() async throws {
        let transport = ProbeTransport()
        let connection = ACPConnection(transport: transport)
        try await connection.start()
        let result = Task { try await connection.call("after-garbage", Empty(), timeout: nil) }
        let request = try #require((await waitForSent(1, by: transport)).first)
        guard case .request(let id, _, _) = try JSONCoding.decoder.decode(
            IncomingMessage.self, from: request
        ) else {
            Issue.record("requete sortante illisible")
            return
        }

        await transport.push(Data("pas du json".utf8))
        await transport.push(try JSONCoding.encoder.encode(RPCReply(id: id, result: true)))
        #expect(try await result.value.decode(Bool.self) == true)
        await connection.stop()
    }

    @Test("Une permission agent vers client rend exactement le choix touche")
    func permissionRoundTrip() async throws {
        let transport = ProbeTransport()
        let connection = ACPConnection(transport: transport)
        try await connection.start()
        let events = await connection.subscribe()
        let permission = Task.detached { () -> ACPConnection.Event? in
            for await event in events { return event }
            return nil
        }

        await transport.push(Data(#"{"jsonrpc":"2.0","id":91,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"tool","title":"Bash","kind":"execute"},"options":[{"optionId":"once","name":"Autoriser une fois","kind":"allow_once"}]}}"#.utf8))

        guard case .permission(_, let respond) = await permission.value else {
            Issue.record("demande de permission non diffusee")
            return
        }
        await respond(.selected("once"))
        let response = try #require((await waitForSent(1, by: transport)).first)
        guard case .response(let id, let value) = try JSONCoding.decoder.decode(
            IncomingMessage.self, from: response
        ) else {
            Issue.record("reponse de permission illisible")
            return
        }
        #expect(id == 91)
        #expect(value["outcome"]?["optionId"]?.stringValue == "once")
        await connection.stop()
    }

    @Test("Une methode agent inconnue recoit method not found")
    func unknownClientMethod() async throws {
        let transport = ProbeTransport()
        let connection = ACPConnection(transport: transport)
        try await connection.start()

        await transport.push(Data(#"{"jsonrpc":"2.0","id":72,"method":"client/inconnue","params":{}}"#.utf8))
        let response = try #require((await waitForSent(1, by: transport)).first)
        guard case .failure(let id, let error) = try JSONCoding.decoder.decode(
            IncomingMessage.self, from: response
        ) else {
            Issue.record("erreur JSON-RPC absente")
            return
        }
        #expect(id == 72)
        #expect(error.code == RPCError.methodNotFound)
        await connection.stop()
    }

    private func waitForSent(_ count: Int, by transport: ProbeTransport) async -> [Data] {
        for _ in 0..<2_000 {
            let frames = await transport.sentFrames()
            if frames.count >= count { return frames }
            await Task.yield()
        }
        Issue.record("aucune trame sortante apres 2 000 passages")
        return await transport.sentFrames()
    }
}

@Suite("Fixtures ACP partagees")
struct ACPFixtureContractTests {
    @Test("Chaque ligne JSONL enregistree reste decodable par Swift")
    func recordedFixturesDecode() throws {
        for name in ["tour-office-chess", "tour-ordre"] {
            let url = try #require(Bundle(for: FixtureBundleToken.self).url(
                forResource: name, withExtension: "jsonl"
            ))
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            #expect(lines.count > 10)
            for (index, line) in lines.enumerated() {
                do {
                    _ = try JSONCoding.decoder.decode(IncomingMessage.self, from: Data(line.utf8))
                } catch {
                    Issue.record("\(name):\(index + 1): \(error)")
                }
            }
        }
    }
}

private final class FixtureBundleToken {}

private struct ProbeFailure: Error {}

private actor ProbeTransport: ACPTransport {
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let sendFailure: Bool
    private var sent: [Data] = []

    init(sendFailure: Bool = false) {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        self.sendFailure = sendFailure
    }

    var frames: AsyncThrowingStream<Data, Error> { stream }
    func connect() async throws {}

    func send(_ frame: Data) async throws {
        if sendFailure { throw ProbeFailure() }
        sent.append(frame)
    }

    func disconnect() async { continuation.finish() }
    func push(_ frame: Data) { continuation.yield(frame) }
    func sentFrames() -> [Data] { sent }
}
