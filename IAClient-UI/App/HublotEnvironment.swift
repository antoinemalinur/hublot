//
//  HublotEnvironment.swift
//  Hublot
//
//  Les effets qui entourent le modele, regroupes derriere une couture interne.
//  La production garde exactement les memes dependances; les tests peuvent les
//  remplacer sans toucher au reseau, au trousseau ou aux notifications.
//

import Foundation

@MainActor
struct HublotEnvironment {
    var readServerURL: () -> String?
    var writeServerURL: (String) -> Void
    var readToken: () -> String?
    var writeToken: (String) -> Void
    var makeConnection: (URL, String) -> ACPConnection
    var now: () -> Date
    var sleep: (Duration) async throws -> Void
    var requestNotificationAuthorization: () async -> Void
    var notifyTurnFinished: (String, String) -> Void
    var notifyPermissionNeeded: (String, String) -> Void

    static var live: HublotEnvironment {
        HublotEnvironment(
            readServerURL: {
            UserDefaults.standard.string(forKey: "hublot.serverURL")
            },
            writeServerURL: { value in
                UserDefaults.standard.set(value, forKey: "hublot.serverURL")
            },
            readToken: { Keychain.read("acp-token") },
            writeToken: { Keychain.save($0, for: "acp-token") },
            makeConnection: { url, token in
                ACPConnection(transport: WebSocketTransport(url: url, token: token))
            },
            now: { .now },
            sleep: { duration in try await Task.sleep(for: duration) },
            requestNotificationAuthorization: { await Notifier.requestAuthorization() },
            notifyTurnFinished: { session, preview in
                Notifier.turnFinished(session: session, preview: preview)
            },
            notifyPermissionNeeded: { tool, detail in
                Notifier.permissionNeeded(tool: tool, detail: detail)
            }
        )
    }

    #if DEBUG
        /// Stockage sans effet de bord pour les ecrans temoins et les tests.
        static func ephemeral(
            serverURL: String = "", token: String = "",
            makeConnection: @escaping (URL, String) -> ACPConnection = { url, token in
                ACPConnection(transport: WebSocketTransport(url: url, token: token))
            }
        ) -> HublotEnvironment {
            var storedURL = serverURL
            var storedToken = token
            return HublotEnvironment(
                readServerURL: { storedURL },
                writeServerURL: { storedURL = $0 },
                readToken: { storedToken },
                writeToken: { storedToken = $0 },
                makeConnection: makeConnection,
                now: { Date(timeIntervalSinceReferenceDate: 808_000_000) },
                sleep: { duration in try await Task.sleep(for: duration) },
                requestNotificationAuthorization: {},
                notifyTurnFinished: { _, _ in },
                notifyPermissionNeeded: { _, _ in }
            )
        }
    #endif
}
