//
//  ContextTideView.swift
//  Hublot
//
//  La fenêtre de contexte dépliée dans le temps : d'où elle vient, à quelle
//  allure elle monte, et ce qu'elle valait à chaque mesure.
//
//  La barre d'état donne un chiffre juste et muet. Cet écran donne la pente —
//  la seule chose qui permette de décider s'il faut compacter maintenant ou
//  finir ce qu'on a commencé.
//

import SwiftUI

struct ContextTideView: View {
    let projectName: String
    let history: [ContextTide.Sample]
    /// Vrai tant que la conversation a un tour en cours.
    ///
    /// Même raison que dans la radiographie : rien dans les mesures ne permet
    /// de le deviner. Une dernière mesure vieille de trois jours a exactement
    /// la même forme qu'une mesure qui vient d'arriver.
    var isLive = false

    @Environment(\.dismiss) private var dismiss
    /// `nil` suit le direct. Une valeur fige le tracé dans son passé.
    @State private var frozenStep: Int?

    private var tide: ContextTide { ContextTide(samples: history) }
    private var snapshot: ContextTide.Snapshot { tide.snapshot(through: frozenStep) }

    /// Un tracé figé dans le passé ne bouge jamais, même sur un fil vivant :
    /// on relit, on ne regarde pas monter.
    private var isAnimating: Bool { isLive && frozenStep == nil }

    /// Le fond suit le contexte, pas l'agitation du moteur : c'est cet écran-là
    /// qu'on ouvre pour savoir si on approche du plafond.
    private var machine: MachineState {
        guard let percent = snapshot.current?.percent else { return .idle }
        if percent >= 90 { return .failed }
        if isAnimating { return .working }
        return .idle
    }

    var body: some View {
        ZStack {
            AmbientBackground(state: machine)

            if snapshot.isEmpty {
                emptyState
            } else {
                field
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        .preferredColorScheme(.dark)
    }

    // MARK: - Le champ

    private var field: some View {
        VStack(spacing: Hublot.unit * 3) {
            Spacer(minLength: 0)

            ContextGauge(
                percent: snapshot.current?.percent,
                size: 210,
                isLive: isAnimating
            )
            .overlay { reading }

            TideCurve(snapshot: snapshot, isLive: isAnimating)
                .frame(height: 140)
                .padding(.horizontal, Hublot.unit)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Hublot.unit * 2)
    }

    /// Le chiffre, au centre de la cuve. En monospace : il vient de la machine.
    private var reading: some View {
        VStack(spacing: 2) {
            if let percent = snapshot.current?.percent {
                Text("\(percent)")
                    .font(.system(size: 44, weight: .light, design: .monospaced))
                    .foregroundStyle(Hublot.prose)
                    .contentTransition(.numericText())
                Text("% DE LA FENÊTRE")
                    .font(.hublotMetaEmphasis)
                    .foregroundStyle(Hublot.meta)
            }
        }
        .shadow(color: Hublot.abyss.opacity(0.8), radius: 6)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: Hublot.unit) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Hublot.prose)
                    .frame(width: 34, height: 34)
                    // Même leçon que sur la radiographie : sans cette forme, la
                    // zone sensible se limite au glyphe et il faut viser.
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityIdentifier("close-context-tide")
            .accessibilityLabel("Fermer la marée de contexte")

            VStack(alignment: .leading, spacing: 2) {
                Text("MARÉE DE CONTEXTE")
                    .font(.hublotMetaEmphasis)
                    .foregroundStyle(Hublot.ember)
                Text(projectName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Hublot.prose)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack(spacing: Hublot.unit * 0.75) {
                Circle()
                    .fill(isAnimating ? Hublot.ember : Hublot.meta)
                    .frame(width: 6, height: 6)
                Text(frozenStep != nil ? "passé" : (isLive ? "direct" : "terminé"))
                    .font(.hublotMeta)
                    .foregroundStyle(Hublot.meta)
            }
            .padding(.horizontal, Hublot.unit * 1.25)
            .padding(.vertical, Hublot.unit * 0.75)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, Hublot.unit * 2)
        .padding(.vertical, Hublot.unit * 1.25)
        .padding(.bottom, Hublot.unit * 2)
        .background { EdgeScrim(edge: .top).ignoresSafeArea() }
    }

    private var controls: some View {
        VStack(spacing: Hublot.unit) {
            if let current = snapshot.current {
                SampleInspector(sample: current, peak: snapshot.peak)
            }

            if !tide.plottable.isEmpty {
                timeline
            }
        }
        .padding(.horizontal, Hublot.unit * 2)
        .padding(.top, Hublot.unit * 3)
        .padding(.bottom, Hublot.unit)
        .background { EdgeScrim(edge: .bottom).ignoresSafeArea() }
    }

    private var timeline: some View {
        VStack(spacing: Hublot.unit * 0.75) {
            HStack {
                Text(stepCaption)
                    .font(.hublotMetaEmphasis)
                    .foregroundStyle(Hublot.meta)
                Spacer()
                if frozenStep != nil {
                    Button(isLive ? "Revenir au direct" : "Revenir à la fin") {
                        withAnimation(.snappy(duration: 0.25)) { frozenStep = nil }
                    }
                    .font(.hublotMetaEmphasis)
                    .foregroundStyle(Hublot.ember)
                    .buttonStyle(.plain)
                }
            }

            if let range = tide.scrubberRange {
                Slider(
                    value: Binding(
                        get: { Double(frozenStep ?? tide.lastStep) },
                        set: { value in
                            let step = Int(value.rounded())
                            frozenStep = step >= tide.lastStep ? nil : step
                        }
                    ),
                    in: range,
                    step: 1
                )
                .tint(Hublot.ember)
                .accessibilityLabel("Chronologie de la marée de contexte")

                HStack {
                    Text("première mesure")
                    Spacer()
                    Text(isLive ? "maintenant" : "dernière mesure")
                }
                .font(.hublotMeta)
                .foregroundStyle(Hublot.meta.opacity(0.75))
            } else {
                HStack(spacing: Hublot.unit * 0.75) {
                    Circle()
                        .fill(Hublot.ember)
                        .frame(width: 5, height: 5)
                    Text("Première mesure")
                    Spacer()
                    Text(isLive ? "maintenant" : "dernière mesure")
                }
                .font(.hublotMeta)
                .foregroundStyle(Hublot.meta.opacity(0.75))
            }
        }
        .padding(Hublot.unit * 1.5)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18, style: .continuous))
    }

    private var stepCaption: String {
        let step = frozenStep ?? tide.lastStep
        return "MESURE \(step + 1) / \(tide.plottable.count)"
    }

    private var emptyState: some View {
        VStack(spacing: Hublot.unit * 1.5) {
            Image(systemName: "gauge.with.dots.needle.bottom.0percent")
                .font(.system(size: 34, weight: .ultraLight))
                .foregroundStyle(Hublot.ember)
                .shadow(color: Hublot.ember.opacity(0.7), radius: 12)
            Text("Aucune mesure de contexte")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Hublot.prose)
            Text("La marée apparaîtra dès que le moteur aura mesuré la fenêtre.")
                .font(.hublotMeta)
                .foregroundStyle(Hublot.meta)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .padding(.bottom, Hublot.unit * 8)
    }
}

// MARK: - La courbe

/// Le tracé des mesures, dans l'ordre où elles sont arrivées.
///
/// L'axe horizontal est celui des **mesures**, pas des secondes : le relais
/// n'échantillonne que pendant qu'un tour tourne, et étirer le tracé sur le
/// temps réel écraserait toute une séance de travail contre une nuit d'inaction.
/// Chaque point garde son horodatage, que l'inspecteur affiche.
private struct TideCurve: View {
    let snapshot: ContextTide.Snapshot
    let isLive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool { isLive && !HublotMotion.isReduced(reduceMotion) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { time in
            Canvas { context, size in
                drawThresholds(in: &context, size: size)
                drawCurve(in: &context, size: size)
                if animates {
                    drawPulse(in: &context, size: size, date: time.date)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// La gouttière de droite : elle porte les étiquettes de seuil, et rien
    /// d'autre. Sans elle, la dernière mesure — celle qu'on vient justement
    /// lire — était coupée par le bord et se cognait au « 90 % ».
    private static let gutter: CGFloat = 34

    /// Les points du tracé, en coordonnées de vue.
    private func points(in size: CGSize) -> [CGPoint] {
        let plotted = snapshot.plotted
        guard !plotted.isEmpty else { return [] }
        // Un seul point n'a pas de pente : on le pose au milieu plutôt qu'au
        // bord, où il se lirait comme le début d'une courbe absente.
        guard plotted.count > 1 else {
            return [CGPoint(
                x: size.width / 2,
                y: height(for: plotted[0], in: size)
            )]
        }
        let span = max(1, size.width - Self.gutter)
        return plotted.enumerated().map { index, sample in
            CGPoint(
                x: span * CGFloat(index) / CGFloat(plotted.count - 1),
                y: height(for: sample, in: size)
            )
        }
    }

    private func height(for sample: ContextTide.Sample, in size: CGSize) -> CGFloat {
        let percent = CGFloat(sample.percent ?? 0) / 100
        return size.height * (1 - percent)
    }

    /// Les deux seuils de la barre d'état, aux mêmes valeurs : ce sont eux qui
    /// donnent une échelle au tracé.
    private func drawThresholds(in context: inout GraphicsContext, size: CGSize) {
        for (percent, color) in [(70, Hublot.ember), (90, Hublot.removed)] {
            let y = size.height * (1 - CGFloat(percent) / 100)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(
                path,
                with: .color(color.opacity(0.28)),
                style: .init(lineWidth: 0.6, dash: [2, 7])
            )
            context.draw(
                Text("\(percent)%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(color.opacity(0.55)),
                at: CGPoint(x: size.width - Self.gutter / 2, y: y - 7)
            )
        }
    }

    private func drawCurve(in context: inout GraphicsContext, size: CGSize) {
        let places = points(in: size)
        guard let first = places.first else { return }

        // Un seul point : un jalon, pas une courbe. Le dessiner en ligne
        // donnerait une pente qu'aucune mesure n'a établie.
        guard places.count > 1 else {
            let dot = CGRect(x: first.x - 3, y: first.y - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: dot), with: .color(Hublot.ember))
            return
        }

        var line = Path()
        line.move(to: first)
        for point in places.dropFirst() { line.addLine(to: point) }

        // Le volume sous la courbe : c'est ce qui fait « marée » plutôt que
        // « graphique ». Fermé sur le bas du cadre.
        var area = line
        area.addLine(to: CGPoint(x: places[places.count - 1].x, y: size.height))
        area.addLine(to: CGPoint(x: first.x, y: size.height))
        area.closeSubpath()
        context.fill(
            area,
            with: .linearGradient(
                Gradient(colors: [
                    Hublot.ember.opacity(0.28), Hublot.ember.opacity(0.02),
                ]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )

        context.stroke(
            line,
            with: .color(Hublot.ember),
            style: .init(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
        )

        // La dernière mesure porte son point : c'est là qu'on en est.
        if let last = places.last {
            let halo = CGRect(x: last.x - 6, y: last.y - 6, width: 12, height: 12)
            let core = CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)
            context.fill(Path(ellipseIn: halo), with: .color(Hublot.ember.opacity(0.18)))
            context.fill(Path(ellipseIn: core), with: .color(Hublot.ember))
        }
    }

    /// Une pulsation sur la dernière mesure, tant que ça monte encore. Ce n'est
    /// pas une prédiction : elle marque le point vivant, elle ne le déplace pas.
    private func drawPulse(in context: inout GraphicsContext, size: CGSize, date: Date) {
        guard let last = points(in: size).last else { return }
        let raw = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 1.8) / 1.8
        let radius = 6 + CGFloat(raw) * 12
        let ring = CGRect(
            x: last.x - radius, y: last.y - radius,
            width: radius * 2, height: radius * 2
        )
        context.stroke(
            Path(ellipseIn: ring),
            with: .color(Hublot.ember.opacity(0.5 * (1 - raw))),
            lineWidth: 1
        )
    }
}

// MARK: - Inspection

/// Ce que la mesure courante dit, en toutes lettres. Rien n'est estimé : les
/// jetons sont ceux qu'on a reçus, le sommet est un point réel du tracé.
private struct SampleInspector: View {
    let sample: ContextTide.Sample
    let peak: ContextTide.Sample?

    private var tint: Color {
        sample.percent.map(StatusBar.tint) ?? Hublot.meta
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Hublot.unit) {
            HStack(spacing: Hublot.unit) {
                Circle().fill(tint).frame(width: 7, height: 7)
                    .shadow(color: tint.opacity(0.7), radius: 5)
                Text(sample.model ?? "modèle inconnu")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Hublot.prose)
                    .lineLimit(1)
                if let engine = sample.engine {
                    Text(engine)
                        .font(.hublotMeta)
                        .foregroundStyle(Hublot.meta)
                }
                Spacer()
                if let at = sample.at {
                    Text(at.formatted(date: .omitted, time: .shortened))
                        .font(.hublotMeta)
                        .foregroundStyle(Hublot.meta)
                }
            }

            Text("\(sample.used.formatted()) / \(sample.size.formatted()) jetons")
                .font(.hublotMono)
                .foregroundStyle(Hublot.prose)

            // Le sommet n'apparaît que s'il est derrière nous : une compaction
            // fait retomber le contexte, et c'est justement ce qu'on veut voir.
            if let peak, let high = peak.percent, let now = sample.percent, high > now {
                Text("sommet atteint : \(high) %")
                    .font(.hublotMeta)
                    .foregroundStyle(Hublot.meta)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Hublot.unit * 1.5)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Écrans témoins

extension ContextTideView {
    #if DEBUG
        /// Une séance ordinaire : le contexte monte, une compaction le fait
        /// retomber, puis il repart. `-HublotContextTideDemo 1` la rend sans
        /// serveur — une feature visuelle doit pouvoir être photographiée à
        /// chaque changement.
        static var demo: ContextTideView {
            let readings: [(Int, Int)] = [
                (4_200, 200_000), (18_600, 200_000), (31_400, 200_000),
                (52_800, 200_000), (78_300, 200_000), (96_100, 200_000),
                (124_500, 200_000), (163_200, 200_000), (184_900, 200_000),
                // La compaction : le fil repart léger.
                (22_400, 200_000), (41_700, 200_000), (58_300, 200_000),
            ]
            let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
            let samples = readings.enumerated().map { index, reading in
                ContextTide.Sample(
                    id: "demo-\(index)", sequence: index,
                    used: reading.0, size: reading.1,
                    at: start.addingTimeInterval(Double(index) * 96),
                    model: "Opus 5", engine: "claude"
                )
            }
            return ContextTideView(
                projectName: "Office Chess", history: samples, isLive: true
            )
        }

        /// Meme donnees, mais sans pulsation temporelle pour la reference
        /// visuelle. Le scenario interactif reste vivant et continue de
        /// verifier le retour au direct.
        static var snapshotDemo: ContextTideView {
            var view = demo
            view.isLive = false
            return view
        }
    #endif
}

#if DEBUG
    #Preview("Marée de contexte") {
        ContextTideView.demo
    }

    #Preview("Marée sans mesure") {
        ContextTideView(projectName: "Office Chess", history: [])
    }
#endif
