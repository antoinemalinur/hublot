//
//  Keychain.swift
//  Hublot
//
//  Le jeton, et rien d'autre. Pas de service tiers, pas de télémétrie, pas de
//  compte : c'est une contrainte du brief, pas une préférence.
//

import Foundation
import Security

nonisolated enum Keychain {

    private static let service = "fr.hublot.acp"

    /// `WhenUnlockedThisDeviceOnly` : le jeton ne part pas dans une sauvegarde
    /// iCloud et ne suit pas sur un autre appareil. Il donne accès à un shell
    /// root sur le VPS — il n'a rien à faire ailleurs que sur ce téléphone.
    ///
    /// Constante calculée et non stockée : `CFString` n'est pas `Sendable`, et
    /// une propriété statique la rendrait partagée entre isolations.
    private static var accessibility: CFString { kSecAttrAccessibleWhenUnlockedThisDeviceOnly }

    static func save(_ value: String, for account: String) {
        delete(account)
        guard !value.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: accessibility,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
