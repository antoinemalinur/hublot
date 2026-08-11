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

    /// Une mesure de la barre. `percent` est nul pour ce qui n'est pas une
    /// jauge — le temps avant remise à zéro n'a pas de seuil d'alerte.
    struct Cell {
        var text: String
        var percent: Int?
    }

    /// Les mesures, dans l'ordre d'affichage.
    static func cells(status: SessionStatus?, contextPercent: Int?) -> [Cell] {
        var parts: [Cell] = []

        // Les deux moteurs ne se mesurent pas sur la même durée, et c'est la
        // fenêtre qui les bloque qu'il faut montrer. Claude est plafonné par sa
        // session de 5 h ; Codex, par sa semaine — `account/rateLimits/read` ne
        // lui rend d'ailleurs que celle-là, `secondary` est nul. Le repli reste
        // là pour l'abonnement qui exposerait l'autre, mais il ne décide plus :
        // demander le 5 h en premier à Codex affichait sa semaine sous une
        // étiquette de cinq heures.
        let quota: (label: String, window: SessionStatus.Window)?
        if status?.engine == Engine.codex.rawValue {
            if let weekly = status?.weekly {
                quota = ("7J", weekly)
            } else if let short = status?.fiveHour {
                quota = ("5H", short)
            } else {
                quota = nil
            }
        } else if let window = status?.fiveHour {
            quota = ("5H", window)
        } else {
            quota = nil
        }

        if let quota {
            parts.append(.init(
                text: "\(quota.label): \(quota.window.percent)%",
                percent: quota.window.percent
            ))
            // La remise à zéro est sa propre cellule : accolée au pourcentage,
            // on lisait « 42 % ↻4:12 » comme une seule quantité.
            if let remaining = quota.window.remaining {
                parts.append(.init(text: "\(reset)\(remaining)", percent: nil))
            }
        }
        if let contextPercent {
            parts.append(.init(text: "CTX \(contextPercent)%", percent: contextPercent))
        }

        return parts
    }

    /// Le texte de la barre, ou `nil` s'il n'y a rien à dire.
    static func content(status: SessionStatus?, contextPercent: Int?) -> String? {
        let parts = cells(status: status, contextPercent: contextPercent)
        return parts.isEmpty ? nil : parts.map(\.text).joined(separator: separator)
    }

    private static let separator = " · "

    /// La même barre, prête à afficher.
    ///
    /// Deux détails de typographie, et un de fond. Le glyphe de remise à zéro
    /// est plus grand que les chiffres — c'est un pictogramme, pas une lettre —
    /// et redescendu de la moitié de ce qu'il a gagné pour rester sur la ligne.
    /// Et **chaque jauge porte sa propre couleur** : une fenêtre de contexte à
    /// 92 % s'affichait exactement comme une à 6 %, alors que la première dit
    /// qu'on approche de la compaction et la seconde qu'on a toute la place du
    /// monde.
    static func label(status: SessionStatus?, contextPercent: Int?) -> AttributedString? {
        let parts = cells(status: status, contextPercent: contextPercent)
        guard !parts.isEmpty else { return nil }

        var label = AttributedString()
        for (index, cell) in parts.enumerated() {
            if index > 0 {
                var gap = AttributedString(separator)
                gap.foregroundColor = Hublot.meta
                label.append(gap)
            }
            var piece = AttributedString(cell.text)
            piece.foregroundColor = cell.percent.map(tint) ?? Hublot.meta
            label.append(piece)
        }

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
