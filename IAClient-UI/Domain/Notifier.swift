//
//  Notifier.swift
//  Hublot
//
//  Prévenir quand la réponse est prête, ou quand l'agent attend une décision.
//
//  Ce sont des notifications **locales** : l'app se réveille elle-même, sans
//  serveur de push. C'est ce qui les rend possibles sous une signature
//  gratuite, où le push est interdit par Apple.
//
//  Leur limite est réelle et il faut la connaître : iOS suspend une app en
//  arrière-plan au bout d'une trentaine de secondes. Tant que Hublot vit —
//  ouvert, ou tout juste basculé — la notification part. Application tuée ou
//  endormie depuis longtemps, personne ne peut la déclencher : il faudra le
//  programme payant et un vrai push côté VPS.
//

import Foundation
import UIKit
import UserNotifications

@MainActor
enum Notifier {

    private static var authorized = false

    /// Demandé une fois, à la première connexion. Un refus n'est pas une
    /// erreur : l'app marche sans, on n'insiste pas.
    static func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorized = true
        case .notDetermined:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            authorized = false
        }
    }

    /// La réponse est arrivée. Rien n'est envoyé si l'app est à l'écran : la
    /// réponse y est déjà visible, notifier serait du bruit.
    static func turnFinished(session: String, preview: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        post(
            id: "turn",
            title: session,
            body: preview.isEmpty ? "Réponse prête." : summarise(preview),
            sound: .default
        )
    }

    /// L'agent attend une autorisation. Celle-ci part **même app ouverte** :
    /// c'est un blocage, pas une information — tant que personne ne répond, le
    /// tour reste suspendu chez l'agent.
    static func permissionNeeded(tool: String, detail: String) {
        post(
            id: "permission",
            title: "Autorisation demandée",
            body: detail.isEmpty ? tool : "\(tool) — \(summarise(detail))",
            sound: .defaultCritical
        )
    }

    private static func post(
        id: String, title: String, body: String, sound: UNNotificationSound
    ) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        content.interruptionLevel = id == "permission" ? .timeSensitive : .active

        // Identifiant stable par type : une deuxième notification remplace la
        // première au lieu d'empiler des rappels du même événement.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil)
        )
    }

    /// Une notification se lit d'un coup d'œil sur un écran verrouillé.
    private static func summarise(_ text: String) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > 120 ? String(flat.prefix(119)) + "…" : flat
    }
}
