//
//  HoldingView.swift
//  Hublot
//
//  L'écran des quelques secondes où il n'y a rien à montrer.
//
//  Il existe parce que son absence coûtait deux fois.
//
//  Au démarrage, l'app affichait le **formulaire d'authentification** le temps
//  d'établir la liaison — un formulaire déjà rempli, qu'on ne devait pas
//  remplir, présenté comme s'il attendait quelque chose. Une page de réglages
//  n'est pas un écran de chargement : elle ne se montre que lorsqu'il y a
//  vraiment un réglage à changer.
//
//  En cours de route, la conversation disparaît le temps qu'une liaison se
//  refasse, et l'écran devenait blanc — pas un chargement, pas une erreur, du
//  blanc, sans un seul élément touchable. La seule sortie était de tuer l'app.
//
//  Un état transitoire doit se voir *et* se quitter. D'où les deux choses ici :
//  la braise qui respire, qui dit que ça travaille, et une issue de secours qui
//  apparaît quand l'attente cesse d'être raisonnable.
//

import SwiftUI

struct HoldingView: View {

    /// Pourquoi on patiente. Les deux cas ne racontent pas la même histoire :
    /// l'un prolonge l'écran de lancement, l'autre est un accroc au milieu du
    /// travail.
    enum Purpose {
        case launching
        case reconnecting

        var caption: String {
            switch self {
            case .launching: "Connexion au VPS…"
            case .reconnecting: "Reprise de la liaison…"
            }
        }

        /// Le nom n'apparaît qu'au lancement : là, l'écran est la suite de
        /// celui du système. Au milieu d'une session, rappeler à l'utilisateur
        /// le nom de l'app qu'il a sous les yeux ne lui apprend rien.
        var showsWordmark: Bool { self == .launching }

        var escape: String {
            switch self {
            case .launching: "Modifier la connexion"
            case .reconnecting: "Revenir aux conversations"
            }
        }

        /// Au lancement, le hublot est le sujet de l'écran. En cours de route,
        /// c'est un accroc : il se fait plus petit, et le fil qu'on attend
        /// reste la chose importante.
        var portholeSize: CGFloat {
            switch self {
            case .launching: 210
            case .reconnecting: 120
            }
        }
    }

    var purpose: Purpose = .reconnecting
    /// L'issue de secours. `nil` sur un écran témoin.
    var onGiveUp: (() -> Void)?

    @State private var isLong = false
    @State private var hasArrived = false

    var body: some View {
        ZStack {
            AmbientBackground(state: .thinking)

            VStack(spacing: Hublot.unit * 2) {
                // L'objet dont l'app porte le nom, enfin montré : on regarde à
                // travers, et de l'autre côté quelque chose travaille. C'est
                // aussi ce que dit l'écran — la liaison s'établit.
                Porthole(size: purpose.portholeSize)
                    .padding(.bottom, Hublot.unit)
                    // Le hublot arrive de loin : il n'apparaît pas, il
                    // s'approche. Deux dixièmes de seconde suffisent à donner
                    // un début à la scène plutôt qu'un affichage.
                    .scaleEffect(hasArrived ? 1 : 0.82)
                    .opacity(hasArrived ? 1 : 0)
                    .blur(radius: hasArrived ? 0 : 6)

                if purpose.showsWordmark {
                    Text("Hublot")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Hublot.prose)
                }

                Text(purpose.caption)
                    .font(.hublotMeta)
                    .foregroundStyle(Hublot.meta)

                // Après dix secondes, l'attente n'est plus un chargement :
                // c'est une panne. On rend la main plutôt que de la garder.
                if isLong, let onGiveUp {
                    Button(purpose.escape, action: onGiveUp)
                        .font(.system(size: 14, weight: .medium))
                        .buttonStyle(.glass)
                        .tint(Hublot.ember)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            withAnimation(.smooth(duration: 0.65)) { hasArrived = true }
            try? await Task.sleep(for: .seconds(10))
            withAnimation(.snappy(duration: 0.3)) { isLong = true }
        }
    }
}

#Preview("Lancement") {
    HoldingView(purpose: .launching, onGiveUp: {})
}

#Preview("Reprise") {
    HoldingView(purpose: .reconnecting, onGiveUp: {})
}
