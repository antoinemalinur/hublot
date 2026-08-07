//
//  ReconnectingView.swift
//  Hublot
//
//  L'écran des quelques secondes où il n'y a rien à montrer.
//
//  Il n'existe que parce que son absence coûtait cher : la conversation
//  disparaît le temps qu'une liaison se refasse, et l'application affichait
//  alors du blanc — pas un chargement, pas une erreur, du blanc, sans un seul
//  élément touchable. La seule sortie était de tuer l'application.
//
//  Un état transitoire doit se voir *et* se quitter. D'où les deux choses ici :
//  la braise qui respire, qui dit que ça travaille, et une issue de secours qui
//  apparaît quand l'attente cesse d'être raisonnable.
//

import SwiftUI

struct ReconnectingView: View {
    /// L'issue de secours. `nil` sur un écran témoin.
    var onGiveUp: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var isLong = false

    var body: some View {
        ZStack {
            AmbientBackground(state: .thinking)

            VStack(spacing: Hublot.unit * 2) {
                // Le même cerclage que l'écran de connexion : c'est le hublot,
                // vu de l'extérieur, pendant que la salle des machines se
                // rallume.
                Circle()
                    .strokeBorder(Hublot.ember, lineWidth: 2)
                    .frame(width: 34, height: 34)
                    .shadow(color: Hublot.ember.opacity(pulse ? 0.85 : 0.25), radius: pulse ? 16 : 6)
                    .scaleEffect(pulse ? 1.06 : 0.96)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                        value: pulse
                    )

                Text("Reprise de la liaison…")
                    .font(.hublotMeta)
                    .foregroundStyle(Hublot.meta)

                // Après dix secondes, l'attente n'est plus une reprise : c'est
                // une panne. On rend la main plutôt que de la garder.
                if isLong, let onGiveUp {
                    Button("Revenir aux conversations", action: onGiveUp)
                        .font(.system(size: 14, weight: .medium))
                        .buttonStyle(.glass)
                        .tint(Hublot.ember)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            pulse = true
            try? await Task.sleep(for: .seconds(10))
            withAnimation(.snappy(duration: 0.3)) { isLong = true }
        }
    }
}

#Preview {
    ReconnectingView(onGiveUp: {})
}
