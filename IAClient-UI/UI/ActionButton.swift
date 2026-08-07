//
//  ActionButton.swift
//  Hublot
//
//  L'action principale d'un écran : « Nouveau projet », « Nouvelle
//  conversation ».
//
//  Elle était une barre pleine — `.glassProminent` teinté de braise. Le
//  problème n'est pas le goût : une teinte prominente *remplit* le verre d'une
//  couleur presque opaque, et le verre cesse d'être du verre. Or c'est la
//  matière même de cette app — le fond porte une lueur, et ce qui est posé
//  dessus doit la réfracter, pas la masquer.
//
//  La braise revient donc là où elle se comporte comme une lumière, et nulle
//  part ailleurs :
//
//  - une **pastille pleine** qui porte le glyphe, avec son halo — c'est la
//    source, le seul endroit vraiment saturé ;
//  - un **liseré** en dégradé sur la capsule, plus vif en haut : le bord d'un
//    verre capte la lumière par le dessus ;
//  - une **flaque de halo** sous la capsule, qui la décolle du fond.
//
//  Le verre, lui, reste clair. Il fait alors ce pour quoi il est fait : montrer
//  le maillage du fond à travers, déformé.
//

import SwiftUI

struct ActionButton: View {
    let title: String
    let symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Hublot.unit * 1.25) {
                EmberDisc(symbol: symbol)
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Hublot.prose)
            }
            // Asymétrique : la pastille apporte déjà sa propre marge optique à
            // gauche. Des marges égales la feraient paraître décentrée.
            .padding(.leading, Hublot.unit * 1.25)
            .padding(.trailing, Hublot.unit * 2.5)
            .padding(.vertical, Hublot.unit * 1.25)
            .contentShape(.capsule)
        }
        .buttonStyle(EmberGlass())
    }
}

/// La source de lumière du bouton. Le dégradé radial est décentré vers le haut
/// à gauche : une bille éclairée d'en haut, pas un rond de couleur.
private struct EmberDisc: View {
    let symbol: String

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            // Le glyphe est creusé dans la braise, pas posé dessus : du sombre
            // sur de la lumière tient le contraste bien mieux que l'inverse.
            .foregroundStyle(Hublot.abyss)
            .frame(width: 30, height: 30)
            .background {
                Circle().fill(
                    RadialGradient(
                        colors: [Color(hex: 0xFFC978), Hublot.ember, Color(hex: 0xC77F22)],
                        center: UnitPoint(x: 0.34, y: 0.24),
                        startRadius: 0, endRadius: 26
                    )
                )
            }
            .shadow(color: Hublot.ember.opacity(isEnabled ? 0.7 : 0), radius: 10)
            .saturation(isEnabled ? 1 : 0.15)
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Le verre et sa lumière. Séparé en une vue imbriquée parce qu'un `ButtonStyle`
/// n'est pas une vue : l'environnement — donc `isEnabled` — n'y est pas suivi.
private struct EmberGlass: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration)
    }

    private struct Surface: View {
        let configuration: Configuration

        @Environment(\.isEnabled) private var isEnabled

        private var glow: Double {
            guard isEnabled else { return 0 }
            return configuration.isPressed ? 0.40 : 0.22
        }

        var body: some View {
            configuration.label
                .glassEffect(.regular.interactive(), in: .capsule)
                .overlay {
                    Capsule().strokeBorder(
                        LinearGradient(
                            colors: [
                                Hublot.ember.opacity(isEnabled ? 0.6 : 0.14),
                                Hublot.ember.opacity(isEnabled ? 0.06 : 0.03),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                }
                // Le halo est porté par le bouton, pas par le fond : c'est lui
                // qui le décolle et lui donne son épaisseur.
                .shadow(color: Hublot.ember.opacity(glow), radius: configuration.isPressed ? 20 : 14, y: 5)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.snappy(duration: 0.22), value: configuration.isPressed)
        }
    }
}

#Preview {
    ZStack {
        AmbientBackground(state: .idle)
        VStack(spacing: Hublot.unit * 3) {
            ActionButton(title: "Nouveau projet", symbol: "plus") {}
            ActionButton(title: "Nouvelle conversation", symbol: "plus.bubble") {}
            ActionButton(title: "Nouvelle conversation", symbol: "plus.bubble") {}
                .disabled(true)
        }
    }
    .preferredColorScheme(.dark)
}
