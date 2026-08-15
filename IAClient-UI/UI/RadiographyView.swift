//
//  RadiographyView.swift
//  Hublot
//
//  La conversation dépliée en espace : où l'agent est allé, dans quel ordre,
//  et quel état chaque région a réellement annoncé.
//

import SwiftUI

struct RadiographyView: View {
    let projectName: String
    let turns: [Turn]
    /// Vrai tant que la conversation a un tour en cours.
    ///
    /// Rien dans le fil ne permet de le deviner : un outil resté « en cours »
    /// dans un historique vieux de trois jours a exactement la même forme qu'un
    /// outil qui tourne. La carte animait donc les deux, et on croyait la voir
    /// rejouer les derniers gestes d'une conversation terminée.
    var isLive = false

    @Environment(\.dismiss) private var dismiss
    /// `nil` suit le direct. Une valeur fige la carte dans son passé.
    @State private var frozenStep: Int?
    @State private var selectedRegionID: String?

    private var radiography: ProjectRadiography { ProjectRadiography(turns: turns) }
    private var snapshot: ProjectRadiography.Snapshot {
        radiography.snapshot(through: frozenStep)
    }

    /// Une carte figée dans le passé ne bouge jamais, même sur un fil vivant :
    /// on est en train de relire, pas de regarder travailler.
    private var isAnimating: Bool { isLive && frozenStep == nil }

    private var machine: MachineState {
        if isLive && snapshot.hasActiveWork { return .working }
        if snapshot.hasFailure { return .failed }
        return .idle
    }

    private var selectedRegion: ProjectRadiography.Region? {
        snapshot.regions.first { $0.id == selectedRegionID }
    }

    var body: some View {
        ZStack {
            AmbientBackground(state: machine)

            if snapshot.regions.isEmpty {
                emptyState
            } else {
                RadiographyField(
                    snapshot: snapshot,
                    selectedRegionID: selectedRegionID,
                    isLive: isAnimating,
                    onSelect: { region in
                        withAnimation(.snappy(duration: 0.24)) {
                            selectedRegionID = selectedRegionID == region.id ? nil : region.id
                        }
                    }
                )
                .padding(.horizontal, Hublot.unit)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        .preferredColorScheme(.dark)
        .onChange(of: snapshot.regions.map(\.id)) { _, visible in
            guard let selectedRegionID, !visible.contains(selectedRegionID) else { return }
            self.selectedRegionID = nil
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: Hublot.unit) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Hublot.prose)
                    .frame(width: 34, height: 34)
                    // Sans cette forme, la zone sensible se limite au glyphe —
                    // onze points de croix au milieu d'un bouton qui en fait
                    // trente-quatre. Il fallait viser, et on croyait que le
                    // clic « ne passait pas ». Tous les autres boutons du
                    // projet en portent une ; celui-ci était le seul oubli.
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityIdentifier("close-radiography")
            .accessibilityLabel("Fermer la radiographie")

            VStack(alignment: .leading, spacing: 2) {
                Text("RADIOGRAPHIE")
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
                // « direct » annonçait le direct sur une conversation finie.
                // Trois états, trois mots : ce qui bouge, ce qui est arrêté, et
                // ce qu'on relit.
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
            if let selectedRegion {
                RegionInspector(region: selectedRegion)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !snapshot.regions.isEmpty {
                RadiographyLegend(snapshot: snapshot)
            }

            if !radiography.events.isEmpty {
                timeline
            }
        }
        .padding(.horizontal, Hublot.unit * 2)
        .padding(.top, Hublot.unit * 3)
        .padding(.bottom, Hublot.unit)
        .background { EdgeScrim(edge: .bottom).ignoresSafeArea() }
        .animation(.snappy(duration: 0.24), value: selectedRegionID)
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

            if let range = radiography.scrubberRange {
                Slider(
                    value: Binding(
                        get: { Double(frozenStep ?? radiography.lastStep) },
                        set: { value in
                            let step = Int(value.rounded())
                            frozenStep = step >= radiography.lastStep ? nil : step
                        }
                    ),
                    in: range,
                    step: 1
                )
                .tint(Hublot.ember)
                .accessibilityLabel("Chronologie de la radiographie")

                HStack {
                    Text("première action")
                    Spacer()
                    Text(isLive ? "maintenant" : "dernière action")
                }
                .font(.hublotMeta)
                .foregroundStyle(Hublot.meta.opacity(0.75))
            } else {
                HStack(spacing: Hublot.unit * 0.75) {
                    Circle()
                        .fill(Hublot.ember)
                        .frame(width: 5, height: 5)
                    Text("Première action observée")
                    Spacer()
                    Text(isLive ? "maintenant" : "dernière action")
                }
                .font(.hublotMeta)
                .foregroundStyle(Hublot.meta.opacity(0.75))
            }
        }
        .padding(Hublot.unit * 1.5)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18, style: .continuous))
    }

    private var stepCaption: String {
        let step = frozenStep ?? radiography.lastStep
        return "ACTION \(step + 1) / \(radiography.events.count)"
    }

    private var emptyState: some View {
        VStack(spacing: Hublot.unit * 1.5) {
            Image(systemName: "scope")
                .font(.system(size: 34, weight: .ultraLight))
                .foregroundStyle(Hublot.ember)
                .shadow(color: Hublot.ember.opacity(0.7), radius: 12)
            Text("Aucune région observée")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Hublot.prose)
            Text("La carte apparaîtra dès qu’un outil touchera un fichier ou un service.")
                .font(.hublotMeta)
                .foregroundStyle(Hublot.meta)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .padding(.bottom, Hublot.unit * 8)
    }
}

// MARK: - Le champ

private struct RadiographyField: View {
    let snapshot: ProjectRadiography.Snapshot
    let selectedRegionID: String?
    /// Vrai quand la conversation travaille **en ce moment**. Une carte figée
    /// ne doit rien animer : la braise qui voyageait sur la dernière transition
    /// donnait l'impression que l'agent rejouait ses derniers gestes, sur une
    /// conversation finie depuis longtemps.
    let isLive: Bool
    let onSelect: (ProjectRadiography.Region) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool { isLive && !reduceMotion }

    var body: some View {
        GeometryReader { geometry in
            let layout = RegionLayout.layout(
                totalSlots: max(snapshot.totalSlots, snapshot.regions.count),
                in: geometry.size
            )
            let positions = places(from: layout)

            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { time in
                Canvas { context, size in
                    drawOrbits(in: &context, layout: layout, size: size)
                    drawLinks(in: &context, positions: positions)
                    if animates {
                        drawCurrent(in: &context, positions: positions, date: time.date)
                    }
                }
            }
            .allowsHitTesting(false)

            ForEach(snapshot.regions) { region in
                if let point = positions[region.id] {
                    RegionNode(
                        region: region,
                        isSelected: selectedRegionID == region.id,
                        isLive: isLive,
                        diameter: RegionLayout.diameter(
                            base: layout.diameter, count: region.count
                        ),
                        labelWidth: layout.labelWidth,
                        action: { onSelect(region) }
                    )
                    .position(point)
                    .transition(.scale(scale: 0.65).combined(with: .opacity))
                }
            }
        }
    }

    /// La place de chaque région visible. Elle vient de son slot, calculé sur
    /// le fil entier : remonter la chronologie ne déplace donc rien.
    private func places(from layout: RegionLayout.Layout) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]
        for region in snapshot.regions {
            if let point = layout.point(forSlot: region.slot) { result[region.id] = point }
        }
        return result
    }

    private func drawOrbits(
        in context: inout GraphicsContext, layout: RegionLayout.Layout, size: CGSize
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // Les orbites du fond sont celles que la disposition occupe vraiment.
        // Dessinées à des fractions arbitraires, elles ne racontaient rien et
        // passaient au travers des disques.
        for radius in layout.orbits where radius.width > 8 {
            let rect = CGRect(
                x: center.x - radius.width, y: center.y - radius.height,
                width: radius.width * 2, height: radius.height * 2
            )
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(Hublot.rule.opacity(0.22)),
                style: .init(lineWidth: 0.6, dash: [2, 7])
            )
        }
    }

    private func drawLinks(
        in context: inout GraphicsContext,
        positions: [String: CGPoint]
    ) {
        for link in snapshot.links {
            guard let start = positions[link.from], let end = positions[link.to] else { continue }
            let control = CGPoint(
                x: (start.x + end.x) / 2,
                y: (start.y + end.y) / 2 - min(32, abs(end.x - start.x) * 0.16)
            )
            var path = Path()
            path.move(to: start)
            path.addQuadCurve(to: end, control: control)
            context.stroke(
                path,
                with: .color(Hublot.ember.opacity(min(0.48, 0.14 + Double(link.count) * 0.08))),
                style: .init(lineWidth: min(2.4, 0.7 + CGFloat(link.count) * 0.3), lineCap: .round)
            )
        }
    }

    /// Une braise voyage sur la dernière transition observée. Ce n'est pas une
    /// prédiction : elle relit simplement l'ordre des deux derniers outils.
    ///
    /// Elle n'a de sens que sur une conversation vivante — d'où le garde-fou
    /// chez l'appelant. Rejouée sur un fil terminé, elle racontait un
    /// mouvement qui n'avait plus lieu.
    private func drawCurrent(
        in context: inout GraphicsContext,
        positions: [String: CGPoint],
        date: Date
    ) {
        guard snapshot.events.count > 1 else { return }
        let end = snapshot.events[snapshot.events.count - 1]
        let start = snapshot.events[snapshot.events.count - 2]
        guard start.regionID != end.regionID,
            let from = positions[start.regionID], let to = positions[end.regionID]
        else { return }

        let raw = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 1.8) / 1.8
        let progress = CGFloat(raw)
        let point = CGPoint(
            x: from.x + (to.x - from.x) * progress,
            y: from.y + (to.y - from.y) * progress
        )
        let halo = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
        let core = CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)
        context.fill(Path(ellipseIn: halo), with: .color(Hublot.ember.opacity(0.12)))
        context.fill(Path(ellipseIn: core), with: .color(Hublot.ember))
    }
}

// MARK: - Régions

private struct RegionNode: View {
    let region: ProjectRadiography.Region
    let isSelected: Bool
    /// La conversation travaille-t-elle encore ? Un anneau qui pulse sur un fil
    /// terminé promet une action qui n'aura jamais lieu.
    let isLive: Bool
    /// Imposé par la disposition : c'est elle qui sait combien de place il
    /// reste, et donc à quelle taille les disques cessent de se toucher.
    let diameter: CGFloat
    let labelWidth: CGFloat
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var tint: Color {
        switch region.state {
        case .observed: Hublot.meta
        case .changed, .active: Hublot.ember
        case .failed: Hublot.removed
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: Hublot.unit * 0.5) {
                ZStack {
                    if region.state == .active && isLive {
                        Circle()
                            .stroke(tint.opacity(0.5), lineWidth: 1)
                            .frame(width: diameter, height: diameter)
                            .scaleEffect(pulse ? 1.4 : 1)
                            .opacity(pulse ? 0 : 0.8)
                            .animation(
                                reduceMotion ? nil : .easeOut(duration: 1.4).repeatForever(autoreverses: false),
                                value: pulse
                            )
                    }

                    Circle()
                        .fill(tint.opacity(region.state == .observed ? 0.08 : 0.14))
                        .overlay {
                            Circle().stroke(tint.opacity(isSelected ? 0.95 : 0.45), lineWidth: isSelected ? 1.8 : 0.8)
                        }
                        .shadow(color: tint.opacity(region.state == .observed ? 0.12 : 0.65), radius: isSelected ? 14 : 8)
                        .frame(width: diameter, height: diameter)

                    Image(systemName: region.latest.kind.symbol)
                        .font(.system(size: diameter * 0.28, weight: .light))
                        .foregroundStyle(tint)

                    if region.state == .failed {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Hublot.prose)
                            .offset(x: diameter * 0.28, y: -diameter * 0.28)
                    }
                }
                .glassEffect(.regular.interactive(), in: .circle)

                // Une carte trop peuplée n'a plus la place de nommer ses
                // régions. Vingt-quatre étiquettes tronquées à quatre lettres
                // n'apprennent rien ; vingt-quatre disques bien séparés se
                // lisent, et se nomment au toucher.
                if labelWidth > 0 {
                    Text(region.name)
                        .font(.hublotMetaEmphasis)
                        .foregroundStyle(isSelected ? Hublot.prose : Hublot.meta)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // Bornée à la largeur que la disposition a réservée : un
                        // nom plus large que sa place recouvre le disque voisin,
                        // et c'est ce qu'on voyait sur une carte chargée.
                        .frame(maxWidth: labelWidth)

                    Text("\(region.count)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Hublot.meta.opacity(0.7))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(region.name), \(region.count) actions, \(stateLabel)")
        .accessibilityIdentifier("region-\(region.name)")
        .onAppear { pulse = true }
    }

    private var stateLabel: String {
        switch region.state {
        case .observed: "observée"
        case .changed: "modifiée"
        case .active: "active"
        case .failed: "en échec"
        }
    }
}

/// Où poser les régions pour qu'aucune n'en recouvre une autre.
///
/// La première version les rangeait toutes sur **une** ellipse. À six régions
/// c'était juste ; à quatorze — ce que donne une vraie séance sur un dépôt —
/// les disques se chevauchaient et les noms se superposaient au point qu'on
/// lisait « Racine » par-dessus « data ». Une carte illisible ne vaut pas mieux
/// qu'une absence de carte.
///
/// Trois principes, dans cet ordre :
///
/// 1. **Ce qu'on mesure, c'est l'encombrement complet** — le disque *et* son
///    nom en dessous. Deux cercles qui ne se touchent pas peuvent parfaitement
///    superposer leurs étiquettes ; c'était le cas le plus fréquent.
/// 2. **Plusieurs orbites**, remplies de l'extérieur vers le centre, chacune
///    portant ce que sa circonférence peut vraiment porter. Les ellipses en
///    pointillé du fond deviennent alors la structure réelle de la carte, et
///    non un décor.
/// 3. **Un dégagement déterministe** pour finir : ce qui se touche encore —
///    typiquement une orbite intérieure et une extérieure aux flancs — est
///    écarté par l'axe où la pénétration est la moindre. Aucun aléa, donc la
///    même conversation donne toujours la même carte.
///
/// Les places sont calculées pour **toutes** les régions du fil, y compris
/// celles qui n'existent pas encore au point choisi dans la chronologie : c'est
/// ce qui empêche les continents de tourner autour de l'écran quand on remonte
/// le temps.
enum RegionLayout {

    struct Layout: Equatable {
        /// Une place par slot, dans l'ordre des slots.
        var slots: [CGPoint]
        /// Le diamètre de base d'un disque, réduit quand la carte se peuple.
        var diameter: CGFloat
        /// La largeur allouée à un nom. Elle rétrécit avec le disque.
        var labelWidth: CGFloat
        /// Les demi-axes des orbites occupées, pour que le fond les dessine là
        /// où les régions se trouvent réellement.
        var orbits: [CGSize]

        func point(forSlot slot: Int) -> CGPoint? {
            slots.indices.contains(slot) ? slots[slot] : nil
        }
    }

    /// Le diamètre le plus généreux, et celui en dessous duquel un glyphe
    /// d'outil n'est plus lisible.
    static let maxDiameter: CGFloat = 58
    static let minDiameter: CGFloat = 34

    /// Un disque grandit un peu avec son activité — mais jamais au-delà de
    /// l'encombrement prévu, sinon la garantie de non-recouvrement tombe.
    static let growth: CGFloat = 1.18

    static func diameter(base: CGFloat, count: Int) -> CGFloat {
        base * (1 + min(growth - 1, CGFloat(count) / 120))
    }

    /// L'encombrement d'une région : son plus gros disque, son nom et son
    /// compteur, plus le filet qui les sépare du voisin.
    ///
    /// Une largeur de nom nulle veut dire que la carte est trop peuplée pour
    /// les afficher : l'encombrement se réduit alors au disque.
    static func footprint(diameter: CGFloat, labelWidth: CGFloat) -> CGSize {
        let disc = diameter * growth
        return CGSize(
            width: max(disc, labelWidth) + 8,
            height: disc + (labelWidth > 0 ? 36 : 12)
        )
    }

    static func labelWidth(for diameter: CGFloat) -> CGFloat {
        min(96, max(58, diameter + 34))
    }

    static func layout(totalSlots: Int, in size: CGSize) -> Layout {
        let count = max(0, totalSlots)
        guard count > 0, size.width > 40, size.height > 40 else {
            return Layout(slots: [], diameter: maxDiameter,
                          labelWidth: labelWidth(for: maxDiameter), orbits: [])
        }

        let fit = fitting(count: count, in: size)
        let box = footprint(diameter: fit.diameter, labelWidth: fit.labelWidth)

        if count == 1 {
            return Layout(
                slots: [CGPoint(x: size.width / 2, y: size.height / 2)],
                diameter: fit.diameter, labelWidth: fit.labelWidth, orbits: []
            )
        }

        var (points, orbits) = onOrbits(count: count, box: box, in: size)
        separate(&points, box: box, in: size)

        // Le dégagement converge presque toujours — mais « presque » ne suffit
        // pas : une carte qui empile deux régions est une carte fausse. Au-delà
        // d'une trentaine de régions sur un téléphone, on abandonne donc la
        // forme orbitale pour une grille, dont la séparation est vraie par
        // construction. Laide et juste plutôt que belle et illisible.
        if !isSeparated(points, box: box) {
            return Layout(
                slots: grid(count: count, box: box, in: size),
                diameter: fit.diameter, labelWidth: fit.labelWidth, orbits: []
            )
        }

        return Layout(
            slots: points, diameter: fit.diameter,
            labelWidth: fit.labelWidth, orbits: orbits
        )
    }

    /// Le critère, écrit une seule fois : deux encombrements se recouvrent tant
    /// que leurs écarts restent inférieurs à leur taille **sur les deux axes**.
    static func isSeparated(_ points: [CGPoint], box: CGSize) -> Bool {
        for i in points.indices {
            for j in points.indices where j > i {
                let dx = abs(points[j].x - points[i].x)
                let dy = abs(points[j].y - points[i].y)
                if dx < box.width && dy < box.height { return false }
            }
        }
        return true
    }

    /// Une grille centrée, dernière rangée comprise.
    ///
    /// Les pas valent la largeur du champ divisée par le nombre de colonnes
    /// qui y tiennent : ils sont donc, par construction, au moins égaux à
    /// l'encombrement d'une région.
    private static func grid(count: Int, box: CGSize, in size: CGSize) -> [CGPoint] {
        let columns = max(1, min(count, Int(size.width / box.width)))
        let rows = max(1, Int(ceil(Double(count) / Double(columns))))
        let stepX = size.width / CGFloat(max(columns, Int(size.width / box.width)))
        let stepY = size.height / CGFloat(max(rows, Int(size.height / box.height)))
        let top = (size.height - stepY * CGFloat(rows)) / 2

        var points: [CGPoint] = []
        for index in 0..<count {
            let row = index / columns
            // La dernière rangée est rarement pleine : la centrer évite le
            // moignon qu'une grille alignée à gauche laisse toujours voir.
            let inRow = min(columns, count - row * columns)
            let column = index % columns
            let left = (size.width - stepX * CGFloat(inRow)) / 2
            points.append(CGPoint(
                x: left + stepX * (CGFloat(column) + 0.5),
                y: top + stepY * (CGFloat(row) + 0.5)
            ))
        }
        return points
    }

    /// Le diamètre retenu, et la place laissée aux noms.
    struct Fit: Equatable {
        var diameter: CGFloat
        /// Zéro quand la carte est trop peuplée pour porter des noms lisibles.
        var labelWidth: CGFloat
    }

    /// Le plus grand disque dont `count` exemplaires tiennent dans le champ.
    ///
    /// Deux réglages qui ont leur importance. Il faut du **mou** : une capacité
    /// tout juste égale au nombre de régions ne laisse plus qu'une grille
    /// parfaite, et le dégagement n'a plus nulle part où pousser. Et au-delà
    /// d'une certaine densité on renonce aux **noms** plutôt qu'à la lisibilité
    /// — vingt-quatre étiquettes tronquées à quatre lettres n'apprennent rien,
    /// alors que vingt-quatre disques bien séparés se lisent encore, et se
    /// nomment au toucher.
    static func fitting(count: Int, in size: CGSize) -> Fit {
        let needed = count + max(2, count / 3)
        for named in [true, false] {
            var candidate = maxDiameter
            while candidate >= minDiameter {
                let label = named ? labelWidth(for: candidate) : 0
                let box = footprint(diameter: candidate, labelWidth: label)
                let columns = max(1, Int(size.width / box.width))
                let rows = max(1, Int(size.height / box.height))
                if columns * rows >= needed {
                    return Fit(diameter: candidate, labelWidth: label)
                }
                candidate -= 2
            }
        }
        return Fit(diameter: minDiameter, labelWidth: 0)
    }

    /// La pose initiale : des ellipses concentriques, remplies du bord vers le
    /// centre, chacune portant ce que sa circonférence peut vraiment porter.
    private static func onOrbits(
        count: Int, box: CGSize, in size: CGSize
    ) -> ([CGPoint], [CGSize]) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let extentX = max(box.width / 2, size.width / 2 - box.width / 2)
        let extentY = max(box.height / 2, size.height / 2 - box.height / 2)
        // Le pas doit convenir dans les deux directions : au sommet de
        // l'ellipse deux voisins s'écartent horizontalement, sur ses flancs
        // verticalement.
        let step = max(box.width, box.height)

        var points: [CGPoint] = []
        var orbits: [CGSize] = []
        var placed = 0
        var turn = 0

        for fraction in [1.0, 0.58, 0.22] where placed < count {
            let radius = CGSize(width: extentX * fraction, height: extentY * fraction)
            let arc = arcLength(radius)
            let room = max(1, Int(arc.total / step))
            let here = min(room, count - placed)
            guard here > 0 else { continue }
            orbits.append(radius)
            // Chaque orbite est décalée d'un demi-pas : sans ça les régions
            // intérieures s'alignent dans l'axe des extérieures et les liaisons
            // se superposent en rayons.
            let offset = Double(turn) * .pi / Double(max(here, 1))
            for index in 0..<here {
                // À **longueur d'arc** égale, pas à angle égal : sur une
                // ellipse allongée, un pas d'angle constant tasse les nœuds aux
                // deux pôles, là où justement ils se recouvraient.
                let angle = arc.angle(atFraction: Double(index) / Double(here)) + offset
                points.append(CGPoint(
                    x: center.x + cos(angle) * radius.width,
                    y: center.y + sin(angle) * radius.height
                ))
            }
            placed += here
            turn += 1
        }

        // Le champ est saturé : le reste part au centre et le dégagement s'en
        // occupe. Mieux vaut une carte serrée qu'une région invisible.
        while placed < count {
            points.append(center)
            placed += 1
        }
        return (points, orbits)
    }

    /// La table des longueurs d'arc d'une ellipse, échantillonnée une fois.
    ///
    /// Il n'y a pas de forme fermée — c'est une intégrale elliptique. Sept cent
    /// vingt échantillons donnent une erreur de l'ordre du millième de point,
    /// très en deçà de ce qu'un œil distingue.
    private struct Arc {
        var cumulative: [CGFloat]
        var total: CGFloat

        /// L'angle atteint après `fraction` du tour, en longueur parcourue.
        func angle(atFraction fraction: Double) -> Double {
            let target = total * CGFloat(min(max(fraction, 0), 1))
            var low = 0
            var high = cumulative.count - 1
            while low < high {
                let middle = (low + high) / 2
                if cumulative[middle] < target { low = middle + 1 } else { high = middle }
            }
            return -Double.pi / 2 + Double(low) * 2 * .pi / Double(cumulative.count - 1)
        }
    }

    private static func arcLength(_ radius: CGSize, samples: Int = 720) -> Arc {
        var cumulative: [CGFloat] = [0]
        cumulative.reserveCapacity(samples + 1)
        var previous = CGPoint(x: radius.width, y: 0)
        var total: CGFloat = 0
        for index in 1...samples {
            let angle = Double(index) * 2 * .pi / Double(samples)
            let point = CGPoint(
                x: radius.width * cos(angle), y: radius.height * sin(angle)
            )
            total += hypot(point.x - previous.x, point.y - previous.y)
            cumulative.append(total)
            previous = point
        }
        return Arc(cumulative: cumulative, total: total)
    }

    /// Écarte ce qui se recouvre encore, par l'axe de moindre pénétration.
    ///
    /// Le critère est celui de deux rectangles : ils se chevauchent tant que
    /// leurs écarts sont inférieurs à l'encombrement **sur les deux axes à la
    /// fois**. Une distance euclidienne ne conviendrait pas — les étiquettes
    /// sont bien plus larges que hautes.
    private static func separate(_ points: inout [CGPoint], box: CGSize, in size: CGSize) {
        guard points.count > 1 else { return }
        for _ in 0..<220 {
            var moved = false
            for i in points.indices {
                for j in points.indices where j > i {
                    let dx = points[j].x - points[i].x
                    let dy = points[j].y - points[i].y
                    let overlapX = box.width - abs(dx)
                    let overlapY = box.height - abs(dy)
                    guard overlapX > 0, overlapY > 0 else { continue }
                    moved = true
                    if overlapX <= overlapY {
                        let push = (overlapX / 2 + 0.5) * (dx < 0 ? -1 : 1)
                        points[i].x -= push
                        points[j].x += push
                    } else {
                        let push = (overlapY / 2 + 0.5) * (dy < 0 ? -1 : 1)
                        points[i].y -= push
                        points[j].y += push
                    }
                }
            }
            clamp(&points, box: box, in: size)
            if !moved { return }
        }
    }

    private static func clamp(_ points: inout [CGPoint], box: CGSize, in size: CGSize) {
        let insetX = min(box.width / 2, size.width / 2)
        let insetY = min(box.height / 2, size.height / 2)
        for index in points.indices {
            points[index].x = min(max(points[index].x, insetX), size.width - insetX)
            points[index].y = min(max(points[index].y, insetY), size.height - insetY)
        }
    }
}

// MARK: - Inspection

private struct RegionInspector: View {
    let region: ProjectRadiography.Region

    private var tint: Color {
        switch region.state {
        case .observed: Hublot.meta
        case .changed, .active: Hublot.ember
        case .failed: Hublot.removed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Hublot.unit) {
            HStack(spacing: Hublot.unit) {
                Circle().fill(tint).frame(width: 7, height: 7)
                    .shadow(color: tint.opacity(0.7), radius: 5)
                Text(region.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Hublot.prose)
                Text("\(region.count) action\(region.count > 1 ? "s" : "")")
                    .font(.hublotMeta)
                    .foregroundStyle(Hublot.meta)
                Spacer()
                Image(systemName: region.latest.kind.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
            }

            Text(region.latest.title)
                .font(.hublotMono)
                .foregroundStyle(Hublot.prose)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let path = region.latest.displayPath {
                Text(path)
                    .font(.hublotMeta)
                    .foregroundStyle(Hublot.meta)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(Hublot.unit * 1.5)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("region-inspector")
    }
}

private struct RadiographyLegend: View {
    let snapshot: ProjectRadiography.Snapshot

    var body: some View {
        HStack(spacing: Hublot.unit * 1.5) {
            item("observé", tint: Hublot.meta)
            item("modifié", tint: Hublot.ember)
            item("échec", tint: Hublot.removed)
            Spacer(minLength: 0)
            Text("\(snapshot.regions.count) région\(snapshot.regions.count > 1 ? "s" : "")")
                .font(.hublotMeta)
                .foregroundStyle(Hublot.meta)
        }
        .padding(.horizontal, Hublot.unit * 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("radiography-legend")
    }

    private func item(_ label: String, tint: Color) -> some View {
        HStack(spacing: Hublot.unit * 0.5) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(label).font(.hublotMeta).foregroundStyle(Hublot.meta)
        }
    }
}

extension RadiographyView {
    #if DEBUG
        static var demo: RadiographyView {
            RadiographyView(
                projectName: "Hublot",
                turns: [
                    .toolCall(.init(
                        id: "read", title: "ChatSession.swift", kind: .read, status: .completed,
                        location: "/root/repos/Hublot/IAClient-UI/Domain/ChatSession.swift"
                    )),
                    .toolCall(.init(
                        id: "edit", title: "ConversationView.swift", kind: .edit,
                        status: .completed,
                        location: "/root/repos/Hublot/IAClient-UI/UI/ConversationView.swift"
                    )),
                    .toolCall(.init(
                        id: "test", title: "xcodebuild test", kind: .execute, status: .inProgress
                    )),
                    .toolCall(.init(
                        id: "server", title: "acp_server.py", kind: .edit, status: .failed,
                        location: "/root/repos/Hublot/Server/acp_server.py"
                    )),
                ],
                isLive: true
            )
        }

        /// La carte telle qu'une vraie séance la produit : quatorze régions,
        /// et une conversation **terminée**.
        ///
        /// Elle existe parce que c'est exactement la situation qui a cassé la
        /// première version — à quatre régions tout allait bien, et rien ne le
        /// montrait. `-HublotRadiographyDense 1` la rend sans serveur.
        static var dense: RadiographyView {
            let places = [
                "office_chess/app.py", "data/matches.db", "README.md",
                "templates/index.html", "bin/serve", ".venv/pyvenv.cfg",
                "backups/manual.db", "static/style.css", "tests/test_api.py",
                "opt/office-chess/config", "docs/notes.md", "scripts/deploy.sh",
            ]
            var turns: [Turn] = places.enumerated().map { index, path in
                .toolCall(.init(
                    id: "place-\(index)",
                    title: URL(fileURLWithPath: path).lastPathComponent,
                    kind: index % 3 == 0 ? .edit : .read,
                    status: index == 4 ? .failed : .completed,
                    location: "/root/repos/office-chess/\(path)"
                ))
            }
            turns.append(.toolCall(.init(
                id: "shell", title: "sqlite3 backups/manual.db 'PRAGMA integrity_check'",
                kind: .execute, status: .completed
            )))
            turns.append(.toolCall(.init(
                id: "reasoning", title: "Task", kind: .think, status: .completed
            )))
            return RadiographyView(projectName: "Office Chess", turns: turns)
        }
    #endif
}

#if DEBUG
    #Preview("Radiographie") {
        RadiographyView.demo
    }

    #Preview("Radiographie chargée") {
        RadiographyView.dense
    }
#endif
