//
//  ContextGauge.swift
//  Hublot
//
//  La chambre de contexte, en volume.
//
//  Le hublot donne sur une salle des machines ; celle-ci donne sur une cuve.
//  Ce qu'on regarde à travers le verre, c'est un niveau qui monte — la fenêtre
//  de contexte qui se remplit. D'où le mot « marée » : pas de l'eau, jamais de
//  bleu, mais une braise qui gagne du terrain vers le cerclage.
//
//  **Comment la profondeur est fabriquée**, exactement comme dans `Porthole` :
//  aucune scène 3D, aucun moteur de rendu. Des plans empilés, inclinés ensemble
//  par `rotation3DEffect` avec perspective, et décalés les uns par rapport aux
//  autres en sens inverse de l'inclinaison. C'est ce parallaxe qui creuse la
//  cuve derrière le verre ; sans lui, le niveau serait un trait peint sur un
//  autocollant.
//
//  Le reflet, lui, va dans l'autre sens encore : fixe dans le monde, il glisse
//  sur le verre quand la chambre bouge.
//
//  Une différence de fond avec `Porthole` : là-bas l'intensité disait un état
//  (au repos, ça travaille). Ici elle porte une **quantité**, et le niveau doit
//  se lire au point près — c'est une mesure, pas une ambiance.
//

import SwiftUI

struct ContextGauge: View {
    /// Le pourcentage de fenêtre consommé, ou `nil` quand rien n'a été mesuré.
    /// L'optionnel n'est pas une commodité : une cuve vide et une cuve dont on
    /// ignore le niveau ne doivent pas se ressembler.
    var percent: Int?
    var size: CGFloat = 210
    /// Vrai quand la conversation travaille : la surface frémit. Sur un fil
    /// terminé elle est étale — un niveau qui bouge annoncerait une montée qui
    /// n'a plus lieu.
    var isLive = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var motionReduced: Bool { HublotMotion.isReduced(reduceMotion) }

    // Le laiton du cerclage, repris à l'identique de `Porthole` : c'est le même
    // atelier qui a fabriqué les deux pièces.
    private static let brassShadow = Color(hex: 0x2A1C0B)
    private static let brass = Color(hex: 0x8A6224)
    private static let brassLit = Color(hex: 0xF3C87A)

    /// La hauteur du niveau, de 0 (fond) à 1 (cerclage).
    private var fill: Double {
        guard let percent else { return 0 }
        return min(max(Double(percent) / 100, 0), 1)
    }

    /// La braise, jusqu'à ce que la compaction menace.
    ///
    /// Volontairement **pas** `StatusBar.tint` : cette échelle-là éteint tout
    /// ce qui est sous soixante-dix pour cent, ce qui est juste pour une
    /// cellule de texte large de six caractères — elle ne doit pas attirer
    /// l'œil quand tout va bien. Ici la cuve *est* le sujet de l'écran ; grise,
    /// elle ne dit plus qu'une chose, que rien ne vaut la peine d'être
    /// regardé. On garde donc l'accent de la maison, et on ne bascule au rouge
    /// qu'au seuil qui compte vraiment.
    private var tint: Color {
        guard let percent else { return Hublot.meta }
        return percent >= 90 ? Hublot.removed : Hublot.ember
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: motionReduced)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            // Mêmes périodes premières entre elles que le hublot : le mouvement
            // ne se répète jamais à l'identique et l'œil ne trouve pas la
            // boucle.
            let yaw = motionReduced ? -6.0 : sin(time * 0.37) * 15
            let pitch = motionReduced ? 4.0 : cos(time * 0.27) * 10
            // La surface ne frémit que si quelque chose se remplit vraiment.
            let swell = (isLive && !motionReduced) ? sin(time * 1.6) : 0

            assembly(yaw: yaw, pitch: pitch, swell: swell, time: time)
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
        .accessibilityElement()
        .accessibilityLabel(
            percent.map { "Contexte à \($0) pour cent" } ?? "Contexte non mesuré"
        )
    }

    private func assembly(
        yaw: Double, pitch: Double, swell: Double, time: TimeInterval
    ) -> some View {
        // Le parallaxe : ce qui est au fond bouge le plus, dans le sens opposé
        // à l'inclinaison. Règle entière de la profondeur, ici comme là-bas.
        let depth = CGSize(
            width: -yaw / 15 * size * 0.05,
            height: pitch / 10 * size * 0.045
        )

        return ZStack {
            halo
            chamber(swell: swell, time: time)
                .offset(x: depth.width, y: depth.height)
                .mask(Circle().inset(by: size * 0.11))
            glass(yaw: yaw, pitch: pitch)
            collar
        }
    }

    /// Ce que la cuve éclaire autour d'elle. Il déborde du cadre — une source
    /// de lumière ne s'arrête pas au bord de l'objet qui la porte — et il
    /// grandit avec le niveau : une chambre presque pleine rayonne davantage.
    private var halo: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        tint.opacity(0.10 + 0.26 * fill),
                        tint.opacity(0.04 + 0.10 * fill),
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

    /// La cuve : un fond sombre, le volume rempli, et sa surface.
    private func chamber(swell: Double, time: TimeInterval) -> some View {
        GeometryReader { geometry in
            let box = geometry.size
            // La surface, mesurée depuis le bas. Le frémissement est minuscule
            // — moins d'un point sur deux cents — parce que c'est une mesure
            // qu'on lit, pas une animation qu'on regarde.
            let level = box.height * (1 - fill) + swell * size * 0.004
            // Le plancher compte plus que la pente : un fond de cuve à peine
            // teinté disparaît sous le voile du pourtour, et il ne reste qu'un
            // trait qui flotte dans le noir. Ce qui est rempli doit se voir
            // rempli, même à un cinquième.
            let lit = min(1.0, 0.58 + fill * 0.42)

            ZStack(alignment: .top) {
                // Le fond du puits, plus froid que celui du hublot : ici rien
                // ne brûle, quelque chose s'accumule.
                Circle().fill(
                    RadialGradient(
                        colors: [
                            Color(hex: 0x14161B),
                            Color(hex: 0x0C0D11),
                            Hublot.abyss,
                        ],
                        center: UnitPoint(x: 0.5, y: 0.42),
                        startRadius: 0,
                        endRadius: size * 0.48
                    )
                )

                // Le volume rempli. Le dégradé va du plus dense en bas au plus
                // clair à la surface : c'est ce qui donne l'épaisseur, un
                // aplat ferait un simple secteur de camembert.
                if fill > 0 {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    tint.opacity(0.26 * lit),
                                    tint.opacity(0.48 * lit),
                                    tint.opacity(0.72 * lit),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .frame(height: max(0, box.height - level))
                        .offset(y: level)
                        .blur(radius: size * 0.004)

                    // La ligne de surface : c'est elle qu'on lit. Elle porte
                    // sa propre lueur, sinon le niveau se devine au lieu de se
                    // mesurer.
                    Rectangle()
                        .fill(tint)
                        .frame(height: max(1, size * 0.006))
                        .shadow(color: tint.opacity(0.9), radius: size * 0.03)
                        .offset(y: level)
                }

                // Les graduations : dix crans, celui des neuf dixièmes marqué.
                // C'est ce qui transforme une lueur en instrument.
                graduations(in: box)

                // L'épaisseur du verre assombrit le pourtour, et seulement le
                // pourtour — même retenue que dans `Porthole`, où pousser ce
                // voile trop loin éteignait toute la scène. Plus léger qu'au
                // hublot : ici c'est le **bas** de la cuve qui porte
                // l'information, et c'est précisément là que le voile mordait.
                Circle().fill(
                    RadialGradient(
                        colors: [.clear, .clear, Hublot.abyss.opacity(0.42)],
                        center: .center,
                        startRadius: size * 0.28, endRadius: size * 0.50
                    )
                )
            }
        }
    }

    /// Les crans, posés **contre la paroi**.
    ///
    /// Leur abscisse suit la corde du cercle à leur hauteur, sinon ils flottent
    /// au milieu du verre et se font couper par le masque en haut et en bas —
    /// ce qui les fait lire comme un artefact plutôt que comme une échelle.
    /// C'est cette demi-corde qui leur donne l'air d'être gravés dans la cuve.
    private func graduations(in box: CGSize) -> some View {
        // Le rayon utile est celui du masque : `Circle().inset(by: 0.11)`.
        let radius = size * 0.39

        return ForEach(1..<10, id: \.self) { step in
            let fraction = Double(step) / 10
            // Le cran des neuf dixièmes est celui du seuil rouge : il se
            // distingue, les autres ne sont que du repère.
            let isThreshold = step == 9
            let length = size * (isThreshold ? 0.07 : 0.04)
            let y = box.height * (1 - fraction)
            let halfChord = (radius * radius - pow(y - box.height / 2, 2)).squareRoot()

            Rectangle()
                .fill(
                    isThreshold
                        ? Hublot.removed.opacity(0.5)
                        : Hublot.rule.opacity(0.55)
                )
                .frame(width: length, height: isThreshold ? 1 : 0.6)
                .offset(x: halfChord - length / 2 - size * 0.012, y: y)
        }
    }

    /// Le verre. Épais : un peu de matière, un reflet large qui glisse, et un
    /// éclat court sur l'arête haute.
    private func glass(yaw: Double, pitch: Double) -> some View {
        // Fixe dans le monde, donc à contresens de la chambre et deux fois plus
        // vite que le fond : c'est ce qui empêche le verre d'être un calque.
        let slide = CGSize(
            width: -yaw / 15 * size * 0.16,
            height: pitch / 10 * size * 0.12
        )

        return ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .opacity(0.12)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.20),
                            .white.opacity(0.05),
                            .clear,
                            tint.opacity(0.08),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .offset(x: slide.width, y: slide.height)
                .blur(radius: size * 0.02)

            Circle()
                .trim(from: 0.60, to: 0.72)
                .stroke(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.5), .clear],
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

            // L'arête intérieure prend la couleur de ce qu'elle contient : elle
            // rattache le cerclage au niveau, et fait monter la chaleur de la
            // pièce entière quand la cuve se remplit.
            Circle()
                .inset(by: size * 0.115)
                .strokeBorder(tint.opacity(0.20 + 0.35 * fill), lineWidth: size * 0.008)
                .blur(radius: size * 0.004)

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

#Preview("Chambre de contexte") {
    ZStack {
        Hublot.abyss.ignoresSafeArea()
        VStack(spacing: 40) {
            ContextGauge(percent: 18, size: 150, isLive: true)
            ContextGauge(percent: 94, size: 150)
        }
    }
}
