//
//  Porthole.swift
//  Hublot
//
//  Le hublot, en volume.
//
//  L'app porte ce nom depuis le premier jour et n'avait jamais montré l'objet.
//  Le voici : un cerclage de laiton, un verre épais, et derrière, la salle des
//  machines qui tourne. C'est l'écran de lancement — le moment où l'app se
//  connecte au VPS — et il dit exactement ce qui se passe : on regarde à
//  travers, quelque chose travaille de l'autre côté.
//
//  **Comment la profondeur est fabriquée.** Aucune scène 3D, aucun moteur de
//  rendu : cinq plans empilés, inclinés ensemble par `rotation3DEffect` avec
//  perspective, et surtout **décalés les uns par rapport aux autres** en sens
//  inverse de l'inclinaison. C'est ce parallaxe qui fait la profondeur. Sans
//  lui, une image inclinée reste un autocollant incliné ; avec lui, l'œil lit
//  un creux réel derrière le verre.
//
//  Les reflets vont dans l'autre sens encore : un reflet est fixe dans le monde,
//  pas sur l'objet, donc il glisse sur le verre quand le hublot bouge. C'est le
//  détail qui achève de rendre le verre crédible.
//
//  Deux couleurs, comme partout ici : la braise et l'abysse.
//

import SwiftUI

struct Porthole: View {
    var size: CGFloat = 190
    /// L'intensité de ce qui brûle derrière : 0 au repos, 1 quand ça travaille.
    var intensity: Double = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var motionReduced: Bool { HublotMotion.isReduced(reduceMotion) }

    // Le laiton du cerclage. Trois valeurs suffisent à faire un métal : l'ombre,
    // la matière, l'arête éclairée.
    private static let brassShadow = Color(hex: 0x2A1C0B)
    private static let brass = Color(hex: 0x8A6224)
    private static let brassLit = Color(hex: 0xF3C87A)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: motionReduced)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            // Deux périodes premières entre elles : le mouvement ne se répète
            // jamais à l'identique, et l'œil ne trouve pas la boucle.
            let yaw = motionReduced ? -6.0 : sin(time * 0.41) * 17
            let pitch = motionReduced ? 4.0 : cos(time * 0.29) * 12
            let breath = motionReduced ? 0.8 : 0.72 + 0.28 * sin(time * 0.85)
            let spin = motionReduced ? 0.0 : time * 26

            assembly(yaw: yaw, pitch: pitch, breath: breath, spin: spin)
                .rotation3DEffect(
                    .degrees(yaw), axis: (x: 0, y: 1, z: 0),
                    anchorZ: 0, perspective: 0.65
                )
                .rotation3DEffect(
                    .degrees(pitch), axis: (x: 1, y: 0, z: 0),
                    anchorZ: 0, perspective: 0.65
                )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func assembly(
        yaw: Double, pitch: Double, breath: Double, spin: Double
    ) -> some View {
        // Le parallaxe : ce qui est au fond bouge le plus, dans le sens opposé
        // à l'inclinaison. C'est la règle entière de la profondeur ici.
        let depth = CGSize(width: -yaw / 17 * size * 0.05, height: pitch / 12 * size * 0.045)

        return ZStack {
            halo(breath: breath)
            engineRoom(breath: breath, spin: spin)
                .offset(x: depth.width, y: depth.height)
                .mask(Circle().inset(by: size * 0.11))
            glass(yaw: yaw, pitch: pitch)
            collar
        }
    }

    /// Ce que le hublot éclaire autour de lui. Il déborde du cadre : une source
    /// de lumière ne s'arrête pas au bord de l'objet qui la porte.
    private func halo(breath: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Hublot.ember.opacity(0.32 * breath * intensity),
                        Hublot.ember.opacity(0.10 * breath * intensity),
                        .clear,
                    ],
                    center: .center,
                    startRadius: size * 0.18,
                    endRadius: size * 0.78
                )
            )
            .scaleEffect(1.7)
            .blur(radius: size * 0.06)
    }

    /// La salle des machines. Trois anneaux qui tournent à des vitesses
    /// différentes : c'est la différence de vitesse qui donne le volume, un
    /// seul anneau ne ferait qu'un disque qui tourne.
    private func engineRoom(breath: Double, spin: Double) -> some View {
        ZStack {
            // Le fond du puits, plus chaud vers le bas — la lumière vient d'en
            // dessous, comme dans une salle des machines.
            Circle().fill(
                RadialGradient(
                    colors: [
                        Color(hex: 0x3A2008),
                        Color(hex: 0x1A0F05),
                        Hublot.abyss,
                    ],
                    center: UnitPoint(x: 0.5, y: 0.60),
                    startRadius: 0,
                    endRadius: size * 0.48
                )
            )

            // Le foyer, **sous** les filaments : ils doivent se détacher devant
            // lui, pas être noyés dedans.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(hex: 0xFFDCA8).opacity(0.98 * breath * intensity),
                            Color(hex: 0xF0A431).opacity(0.80 * breath * intensity),
                            Hublot.ember.opacity(0.30 * breath * intensity),
                            .clear,
                        ],
                        center: .center, startRadius: 0, endRadius: size * 0.28
                    )
                )
                .frame(width: size * 0.56, height: size * 0.56)
                .blur(radius: size * 0.04)

            filament(radius: 0.33, width: 0.022, arc: 0.30, angle: spin, alpha: 1.0 * breath)
            filament(radius: 0.25, width: 0.016, arc: 0.22, angle: -spin * 1.6 + 120, alpha: 0.85 * breath)
            filament(radius: 0.17, width: 0.012, arc: 0.45, angle: spin * 2.4 + 40, alpha: 0.7 * breath)

            // L'épaisseur du verre assombrit le pourtour — mais seulement le
            // pourtour. Poussé trop loin, ce voile éteignait toute la salle des
            // machines et le hublot n'était plus qu'un bouton de laiton.
            Circle().fill(
                RadialGradient(
                    colors: [.clear, .clear, Hublot.abyss.opacity(0.55)],
                    center: .center, startRadius: size * 0.28, endRadius: size * 0.50
                )
            )
        }
    }

    /// Un arc lumineux à une distance donnée de l'axe.
    private func filament(
        radius: CGFloat, width: CGFloat, arc: CGFloat, angle: Double, alpha: Double
    ) -> some View {
        Circle()
            .trim(from: 0, to: arc)
            .stroke(
                LinearGradient(
                    colors: [
                        Hublot.ember.opacity(0),
                        Hublot.ember.opacity(alpha * intensity),
                        Color(hex: 0xFFD9A0).opacity(alpha * intensity),
                        Hublot.ember.opacity(0),
                    ],
                    startPoint: .leading, endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: size * width, lineCap: .round)
            )
            .frame(width: size * radius * 2, height: size * radius * 2)
            .rotationEffect(.degrees(angle))
            .blur(radius: size * 0.008)
    }

    /// Le verre. Épais, donc : un peu de matière, un reflet large qui glisse, et
    /// un éclat court sur l'arête haute.
    private func glass(yaw: Double, pitch: Double) -> some View {
        // Le reflet est fixe dans le monde : il se déplace donc à l'inverse du
        // hublot, et deux fois plus vite que le fond. C'est ce qui empêche le
        // verre de ressembler à un calque.
        let slide = CGSize(width: -yaw / 17 * size * 0.16, height: pitch / 12 * size * 0.12)

        return ZStack {
            // Très peu de matière : le verre d'un hublot est transparent, pas
            // dépoli. À 0,30 il faisait un couvercle laiteux sur la lumière.
            Circle()
                .fill(.ultraThinMaterial)
                .opacity(0.12)

            // Le reflet principal, en écharpe.
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.22),
                            .white.opacity(0.05),
                            .clear,
                            Hublot.ember.opacity(0.10),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .offset(x: slide.width, y: slide.height)
                .blur(radius: size * 0.02)

            // L'éclat court : une virgule sur l'arête, en haut à gauche.
            Circle()
                .trim(from: 0.60, to: 0.72)
                .stroke(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.55), .clear],
                        startPoint: .top, endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: size * 0.018, lineCap: .round)
                )
                .frame(width: size * 0.74, height: size * 0.74)
                .offset(x: slide.width * 1.4, y: slide.height * 1.4)
                .blur(radius: size * 0.006)
        }
        .mask(Circle().inset(by: size * 0.11))
    }

    /// Le cerclage de laiton et ses boulons.
    private var collar: some View {
        ZStack {
            // Le métal : un dégradé angulaire, parce qu'un cylindre poli
            // renvoie la lumière différemment selon l'angle qu'il présente.
            Circle()
                .strokeBorder(
                    AngularGradient(
                        stops: [
                            .init(color: Self.brassShadow, location: 0.00),
                            .init(color: Self.brass, location: 0.13),
                            .init(color: Self.brassLit, location: 0.24),
                            .init(color: Self.brass, location: 0.38),
                            .init(color: Self.brassShadow, location: 0.55),
                            .init(color: Self.brass, location: 0.70),
                            .init(color: Self.brassLit, location: 0.80),
                            .init(color: Self.brass, location: 0.90),
                            .init(color: Self.brassShadow, location: 1.00),
                        ],
                        center: .center,
                        angle: .degrees(-115)
                    ),
                    lineWidth: size * 0.085
                )

            // L'arête intérieure, éclairée par ce qui brûle derrière : c'est
            // elle qui rattache le cerclage à la lumière du fond.
            Circle()
                .inset(by: size * 0.115)
                .strokeBorder(Hublot.ember.opacity(0.45), lineWidth: size * 0.008)
                .blur(radius: size * 0.004)

            // L'arête extérieure, fine et froide.
            Circle()
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)

            bolts
        }
        .shadow(color: Hublot.abyss.opacity(0.9), radius: size * 0.06, y: size * 0.03)
    }

    private var bolts: some View {
        ForEach(0..<8, id: \.self) { index in
            let angle = Double(index) / 8 * 2 * .pi - .pi / 2
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Self.brassLit, Self.brass, Self.brassShadow],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(width: size * 0.036, height: size * 0.036)
                .overlay {
                    Circle().strokeBorder(Hublot.abyss.opacity(0.55), lineWidth: 0.5)
                }
                .offset(
                    x: cos(angle) * size * 0.457,
                    y: sin(angle) * size * 0.457
                )
        }
    }
}

#Preview {
    ZStack {
        Hublot.abyss.ignoresSafeArea()
        Porthole(size: 220)
    }
}
