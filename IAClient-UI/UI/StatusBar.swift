//
//  StatusBar.swift
//  Hublot
//
//  Ce qui ne s'affiche nulle part ailleurs : la consommation du plafond de 5 h,
//  le temps avant sa remise à zéro, et la fenêtre de contexte entamée.
//
//      5H: 42% · ↻4:12 · CTX 18%
//
//  Trois mesures, trois cellules séparées par le même point médian. Les
//  étiquettes sont en capitales pour se distinguer des chiffres sans avoir à
//  changer de graisse — c'est de la signalétique, pas de la prose.
//
//  Deux règles reprises de la barre du terminal. Un champ absent n'est pas
//  fabriqué : devant un plafond, un chiffre faux est pire que pas de chiffre.
//  Et quand rien n'est connu, la barre **disparaît** — une ligne de tirets
//  n'apprend rien et occupe la place.
//

import SwiftUI

enum StatusBar {

    /// Le glyphe de remise à zéro. Isolé pour qu'on puisse le grossir : à la
    /// taille du texte il se lit comme une lettre, alors que c'est un
    /// pictogramme et qu'il doit s'attraper d'un coup d'œil.
    static let reset = "↻"

    /// Le texte de la barre, ou `nil` s'il n'y a rien à dire.
    static func content(status: SessionStatus?, contextPercent: Int?) -> String? {
        var parts: [String] = []

        // Les abonnements n'exposent pas les mêmes fenêtres. Claude fournit
        // normalement 5 h ; Codex, sur ce compte, fournit la semaine. Afficher
        // inconditionnellement le 5 h revenait à laisser le quota Claude sous
        // une session Codex.
        let quota: (label: String, window: SessionStatus.Window)?
        if status?.engine == Engine.codex.rawValue {
            if let short = status?.fiveHour {
                quota = ("5H", short)
            } else if let weekly = status?.weekly {
                quota = ("7J", weekly)
            } else {
                quota = nil
            }
        } else if let window = status?.fiveHour {
            quota = ("5H", window)
        } else {
            quota = nil
        }

        if let quota {
            parts.append("\(quota.label): \(quota.window.percent)%")
            // La remise à zéro est sa propre cellule : accolée au pourcentage,
            // on lisait « 42 % ↻4:12 » comme une seule quantité.
            if let remaining = quota.window.remaining { parts.append("\(reset)\(remaining)") }
        }
        if let contextPercent {
            parts.append("CTX \(contextPercent)%")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// La même barre, prête à afficher : le glyphe de remise à zéro y est plus
    /// grand que les chiffres, et redescendu de la moitié de ce qu'il a gagné
    /// pour rester centré sur la ligne.
    static func label(status: SessionStatus?, contextPercent: Int?) -> AttributedString? {
        guard let text = content(status: status, contextPercent: contextPercent) else {
            return nil
        }
        var label = AttributedString(text)
        label.font = .hublotMeta
        if let range = label.range(of: reset) {
            label[range].font = .system(size: Hublot.metaSize + 4, design: .monospaced)
            label[range].baselineOffset = -1.5
        }
        return label
    }

    /// Le seuil de bascule vers Codex est à 98 % : la couleur doit prévenir
    /// avant, pas au moment où c'est trop tard.
    static func tint(_ percent: Int) -> Color {
        switch percent {
        case ..<70: Hublot.meta
        case ..<90: Hublot.ember
        default: Hublot.removed
        }
    }
}
