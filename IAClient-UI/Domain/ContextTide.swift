//
//  ContextTide.swift
//  Hublot
//
//  La montée du contexte, lue comme une marée.
//
//  La barre d'état dit « CTX 42 % » — un chiffre juste, et muet. Il ne dit ni
//  d'où l'on vient, ni à quelle vitesse on y va, ni si le palier tient depuis
//  dix secondes ou depuis dix minutes. Or c'est exactement ce qu'on veut savoir
//  quand on approche de la compaction : non pas « où en est-on », mais « à
//  quelle allure ça monte ».
//
//  Comme la radiographie, cette projection ne dessine que des faits mesurés.
//  Elle n'interpole pas entre deux échantillons, ne devine pas la suite, et
//  n'invente aucun point là où le relais n'a rien envoyé. Un tracé qui remplit
//  ses trous ment sur ce qu'il sait.
//

import Foundation

/// La suite des mesures de contexte d'une conversation, projetée en tracé.
///
/// Elle ne dépend pas de SwiftUI : les tests vérifient ainsi qu'une mesure
/// impossible reste hors du tracé, et qu'une fenêtre qui change de taille en
/// cours de route ne fausse pas les points déjà posés.
struct ContextTide {

    /// Une mesure, telle que `usage_update` l'a apportée.
    struct Sample: Identifiable, Equatable {
        let id: String
        let sequence: Int
        /// Les jetons portés par la conversation au moment de la mesure.
        let used: Int
        /// La fenêtre du modèle **à cet instant**. Elle n'est pas constante :
        /// changer de modèle ou de moteur en cours de conversation la change,
        /// et Codex n'annonce parfois aucune taille du tout.
        let size: Int
        /// L'instant de la mesure. Absent des fils enregistrés avant que le
        /// serveur ne l'ajoute — d'où l'optionnel, qui n'est pas un oubli.
        let at: Date?
        let model: String?
        let engine: String?

        /// Le pourcentage de fenêtre consommé, ou `nil` si la mesure ne permet
        /// pas de le calculer honnêtement.
        ///
        /// Même règle que `ChatSession.contextPercent`, et pour la même raison
        /// vécue : le serveur a réellement envoyé le total des jetons d'un tour
        /// à la place du contexte porté, ce qui donnait 1540 %. Un point hors
        /// de l'échelle déforme tout le tracé autour de lui — bien plus qu'il
        /// n'informe. On l'écarte donc, plutôt que de le ramener de force à
        /// cent : un plafond touché et un chiffre incohérent ne se ressemblent
        /// pas, et les confondre serait mentir une seconde fois.
        var percent: Int? {
            guard size > 0, used > 0 else { return nil }
            let value = Int((Double(used) / Double(size)) * 100)
            return value <= 100 ? value : nil
        }
    }

    /// L'état du tracé à un point donné de la chronologie.
    struct Snapshot: Equatable {
        let plotted: [Sample]

        /// La mesure la plus récente du tracé — celle que la jauge affiche.
        var current: Sample? { plotted.last }

        /// La plus haute valeur atteinte, qui peut être derrière nous : une
        /// compaction fait retomber le contexte, et le sommet franchi reste un
        /// fait de la conversation.
        var peak: Sample? {
            plotted.max { ($0.percent ?? 0) < ($1.percent ?? 0) }
        }

        var isEmpty: Bool { plotted.isEmpty }
    }

    let samples: [Sample]

    init(samples: [Sample]) {
        self.samples = samples
    }

    /// Les seules mesures que le tracé peut porter. Le filtre vit ici, à la
    /// projection — jamais à l'enregistrement : `ChatSession` retient tout ce
    /// que le relais envoie, exactement comme le fil retient tous les appels
    /// d'outils que la radiographie compte ensuite.
    var plottable: [Sample] { samples.filter { $0.percent != nil } }

    var lastStep: Int { max(0, plottable.count - 1) }

    /// Une chronologie ne devient navigable qu'à partir de deux mesures.
    ///
    /// Même précondition que la radiographie : SwiftUI refuse un `Slider` dont
    /// les deux bornes sont identiques, et la garder dans le modèle empêche la
    /// vue de fabriquer `0...0` pendant qu'une seule mesure est connue.
    var scrubberRange: ClosedRange<Double>? {
        guard plottable.count > 1 else { return nil }
        return 0...Double(lastStep)
    }

    /// Le tracé jusqu'à la mesure demandée. `nil` signifie le direct.
    func snapshot(through step: Int? = nil) -> Snapshot {
        let plotted = plottable
        guard !plotted.isEmpty else { return Snapshot(plotted: []) }

        let end = min(max(step ?? lastStep, 0), lastStep)
        return Snapshot(plotted: Array(plotted.prefix(end + 1)))
    }
}
